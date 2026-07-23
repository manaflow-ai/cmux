import CmuxSimulator
import Darwin
import Foundation
import IOSurface
import ObjectiveC.runtime

/// Direct SimulatorKit framebuffer attachment.
///
/// The descriptor discovery and callback contract are adapted from serve-sim
/// (Apache-2.0, Evan Bacon) and Baguette (Apache-2.0, tddworks). This worker
/// keeps every descriptor and IOSurface reference out of the cmux process.
@MainActor
final class SimulatorFramebuffer {
    private let callbackQueue = DispatchQueue.main
    private let onFrameTransportChange: @MainActor (SimulatorFrameTransportDescriptor) -> Void
    private let onDisplayChange: @MainActor (SimulatorDisplayMetadata) -> Void
    private let beforeFrameTransportChange: @Sendable () async -> Void
    private let afterFrameTransportChange: @Sendable () async -> Void

    private var descriptors: [NSObject] = []
    private var integratedDisplay: (descriptor: NSObject, properties: NSObject)?
    private var callbackIdentifiers: [ObjectIdentifier: NSUUID] = [:]
    private var ioClient: NSObject?
    private var framePublisher: SimulatorFramebufferFramePublisher?
    private var framePublisherGeneration: UInt64 = 0
    private var publishingEnabled = true
    private var orientationState = SimulatorFramebufferOrientationState()
    private var nativeOrientationRawValue: UInt32?
    private var displayScale = 1.0
    private var lastPublishedMetadata: SimulatorDisplayMetadata?
    private var targetGeometry: SimulatorSurfaceGeometry?

    init(
        onFrameTransportChange: @escaping @MainActor (SimulatorFrameTransportDescriptor) -> Void,
        onDisplayChange: @escaping @MainActor (SimulatorDisplayMetadata) -> Void,
        beforeFrameTransportChange: @escaping @Sendable () async -> Void = {},
        afterFrameTransportChange: @escaping @Sendable () async -> Void = {},
        targetGeometry: SimulatorSurfaceGeometry? = nil
    ) {
        self.onFrameTransportChange = onFrameTransportChange
        self.onDisplayChange = onDisplayChange
        self.beforeFrameTransportChange = beforeFrameTransportChange
        self.afterFrameTransportChange = afterFrameTransportChange
        self.targetGeometry = targetGeometry
    }

    deinit {
        MainActor.assumeIsolated {
            stop()
        }
    }

    func start(device: NSObject) async throws {
        stop()
        publishingEnabled = true
        guard let io = objectProperty(device, selectorName: "io") as? NSObject else {
            throw SimulatorWorkerFailure.framebufferUnavailable("Simulator device I/O is unavailable.")
        }
        ioClient = io
        try wireFramebuffer()

        guard publishLatest(readNativeOrientation: true) else {
            stop()
            throw SimulatorWorkerFailure.framebufferUnavailable(
                "SimulatorKit registered display callbacks but did not publish an IOSurface."
            )
        }
        guard let initialDisplay = bestDisplay(readNativeOrientation: false) else {
            stop()
            throw SimulatorWorkerFailure.framebufferUnavailable(
                "SimulatorKit did not retain its initial framebuffer surface."
            )
        }
        try await startPublisher(initialSurface: initialDisplay.surface)
        _ = publishLatest(readNativeOrientation: true)
    }

    func stop() {
        framePublisherGeneration &+= 1
        lastPublishedMetadata = nil
        orientationState.reset()
        nativeOrientationRawValue = nil
        unregisterCallbacks()
        descriptors.removeAll()
        integratedDisplay = nil
        callbackIdentifiers.removeAll()
        ioClient = nil
        framePublisher?.cancel()
        framePublisher = nil
    }

    func setPublishingEnabled(_ enabled: Bool) async throws {
        guard publishingEnabled != enabled else { return }
        if !enabled {
            publishingEnabled = false
            framePublisherGeneration &+= 1
            framePublisher?.cancel()
            framePublisher = nil
            return
        }
        guard let surface = bestDisplay(readNativeOrientation: false)?.surface else {
            throw SimulatorWorkerFailure.framebufferUnavailable(
                "SimulatorKit retained no framebuffer surface while resuming publication."
            )
        }
        publishingEnabled = true
        do {
            try await startPublisher(initialSurface: surface)
        } catch {
            publishingEnabled = false
            throw error
        }
        _ = publishLatest(readNativeOrientation: true)
    }

    func setTargetGeometry(_ geometry: SimulatorSurfaceGeometry) {
        guard targetGeometry != geometry else { return }
        targetGeometry = geometry
        _ = publishLatest()
    }

    func prioritizeNextFrame() {
        framePublisher?.prioritizeNextFrame()
    }

    private func startPublisher(initialSurface: IOSurface) async throws {
        let publisherGeneration = framePublisherGeneration
        let publisher = try await SimulatorFramebufferFramePublisher(
            initialSurface: initialSurface,
            initialGeometry: targetGeometry,
            beforeFrameTransportChange: beforeFrameTransportChange,
            afterFrameTransportChange: afterFrameTransportChange,
            onFrameTransportChange: { [weak self] transport in
                guard let self,
                      self.framePublisherGeneration == publisherGeneration,
                      self.framePublisher != nil else { return }
                self.onFrameTransportChange(transport)
            }
        )
        guard publishingEnabled, framePublisherGeneration == publisherGeneration else {
            publisher.cancel()
            throw CancellationError()
        }
        framePublisher = publisher
        onFrameTransportChange(publisher.initialDescriptor)
    }

    private func unregisterCallbacks() {
        let selector = NSSelectorFromString("unregisterScreenCallbacksWithUUID:")
        for descriptor in descriptors {
            guard let identifier = callbackIdentifiers[ObjectIdentifier(descriptor)],
                descriptor.responds(to: selector)
            else {
                continue
            }
            descriptor.perform(selector, with: identifier)
        }
    }

    private func wireFramebuffer() throws {
        guard let ioClient else {
            throw SimulatorWorkerFailure.framebufferUnavailable("Simulator device I/O is unavailable.")
        }
        _ = invokeVoid(ioClient, selectorName: "updateIOPorts")
        let ports =
            objectProperty(ioClient, selectorName: "ioPorts") as? [NSObject]
            ?? objectProperty(ioClient, selectorName: "deviceIOPorts") as? [NSObject]
        guard let ports else {
            throw SimulatorWorkerFailure.framebufferUnavailable(
                "SimulatorKit did not publish device I/O ports.")
        }

        var candidates: [NSObject] = []
        for port in ports {
            guard let descriptor = objectProperty(port, selectorName: "descriptor") as? NSObject,
                hasSimulatorFramebufferSurface(descriptor)
            else {
                continue
            }
            candidates.append(descriptor)
        }
        guard !candidates.isEmpty else {
            throw SimulatorWorkerFailure.framebufferUnavailable(
                "No Simulator framebuffer display descriptor is available."
            )
        }

        unregisterCallbacks()
        callbackIdentifiers.removeAll()
        descriptors = candidates
        do {
            for descriptor in candidates {
                try registerCallbacks(on: descriptor)
            }
            // SimulatorKit publishes screen identity and surfaces lazily when
            // callbacks attach. Inspecting descriptors before registration can
            // reject a valid display immediately after app or worker restart.
            guard refreshIntegratedDisplay() else {
                throw SimulatorWorkerFailure.framebufferUnavailable(
                    "SimulatorKit did not publish one identifiable integrated display."
                )
            }
        } catch {
            unregisterCallbacks()
            callbackIdentifiers.removeAll()
            descriptors.removeAll()
            throw error
        }
    }

    func setOrientation(_ orientation: SimulatorOrientation) {
        orientationState.request(orientation)
        _ = publishLatest()
    }

    private func registerCallbacks(on descriptor: NSObject) throws {
        let selector = NSSelectorFromString(
            "registerScreenCallbacksWithUUID:callbackQueue:frameCallback:"
                + "surfacesChangedCallback:propertiesChangedCallback:"
        )
        guard descriptor.responds(to: selector) else {
            throw SimulatorWorkerFailure.framebufferUnavailable(
                "The active SimulatorKit does not support framebuffer callbacks."
            )
        }

        let identifier = NSUUID()
        callbackIdentifiers[ObjectIdentifier(descriptor)] = identifier
        let frameCallback: @convention(block) () -> Void = { @MainActor [weak self] in
            _ = self?.publishLatest()
        }
        let surfacesChangedCallback: @convention(block) () -> Void = { @MainActor [weak self] in
            self?.handleSurfaceTopologyChange()
        }
        let propertiesChangedCallback: @convention(block) () -> Void = {
            @MainActor [weak self, weak descriptor] in
            guard let descriptor else { return }
            self?.handleDisplayPropertiesChange(descriptor)
        }

        guard
            sendFiveObjectMessage(
                descriptor,
                selector,
                identifier,
                callbackQueue,
                frameCallback as AnyObject,
                surfacesChangedCallback as AnyObject,
                propertiesChangedCallback as AnyObject
            )
        else {
            throw SimulatorWorkerFailure.framebufferUnavailable(
                "Objective-C message dispatch is unavailable for framebuffer callbacks."
            )
        }
    }

    private func handleSurfaceTopologyChange() {
        _ = refreshIntegratedDisplay()
        if publishLatest(readNativeOrientation: true) { return }
        // A surface-change callback is the synchronization signal that the
        // old descriptor became stale. Re-enumerate once for that event.
        try? wireFramebuffer()
        _ = publishLatest(readNativeOrientation: true)
    }

    private func handleDisplayPropertiesChange(_ descriptor: NSObject) {
        _ = refreshIntegratedDisplay()
        guard integratedDisplay.map({ ObjectIdentifier($0.descriptor) })
            == ObjectIdentifier(descriptor) else {
            // Auxiliary display callbacks may arrive while a requested
            // built-in rotation is still settling. They cannot make the
            // built-in display's cached orientation authoritative.
            _ = publishLatest()
            return
        }
        _ = publishLatest(
            readNativeOrientation: true,
            nativeOrientationIsAuthoritative: true
        )
    }

    @discardableResult
    private func publishLatest(
        readNativeOrientation: Bool = false,
        nativeOrientationIsAuthoritative: Bool = false
    ) -> Bool {
        guard publishingEnabled else { return false }
        guard let display = bestDisplay(readNativeOrientation: readNativeOrientation) else {
            return false
        }
        let freshNativeOrientation = display.orientationRawValue.flatMap { rawValue in
            simulatorNativeOrientation(rawValue: rawValue) == nil ? nil : rawValue
        }
        if let rawValue = freshNativeOrientation {
            nativeOrientationRawValue = rawValue
        }
        let surface = display.surface
        let width = IOSurfaceGetWidth(surface)
        let height = IOSurfaceGetHeight(surface)
        guard width > 0, height > 0 else { return false }
        framePublisher?.enqueue(surface, geometry: targetGeometry)

        let orientation = orientationState.observe(
            width: width,
            height: height,
            nativeRawValue: nativeOrientationRawValue,
            nativeValueIsAuthoritative: nativeOrientationIsAuthoritative
                && freshNativeOrientation != nil
        )
        let metadata = SimulatorDisplayMetadata(
            width: width,
            height: height,
            orientation: orientation,
            scale: displayScale
        )
        if metadata != lastPublishedMetadata {
            lastPublishedMetadata = metadata
            onDisplayChange(metadata)
        }
        return true
    }

    private func bestDisplay(
        readNativeOrientation: Bool
    ) -> (surface: IOSurface, orientationRawValue: UInt32?)? {
        guard let integratedDisplay,
              let surface = simulatorFramebufferSurface(integratedDisplay.descriptor) as? IOSurface
        else { return nil }
        let orientationRawValue = readNativeOrientation
            ? simulatorUnsignedIntegerProperty(
                integratedDisplay.properties,
                selectorName: "uiOrientation"
            )
            : nil
        return (surface, orientationRawValue)
    }

    @discardableResult
    private func refreshIntegratedDisplay() -> Bool {
        var candidates: [(
            descriptor: NSObject,
            surface: IOSurface,
            screenID: UInt32,
            isIntegrated: Bool,
            properties: NSObject
        )] = []
        for descriptor in descriptors {
            guard let rawSurface = simulatorFramebufferSurface(descriptor) else {
                continue
            }
            guard let surface = rawSurface as? IOSurface else { continue }
            guard let properties = objectProperty(
                descriptor,
                selectorName: "screenProperties"
            ) as? NSObject,
                let screenID = simulatorUnsignedIntegerProperty(
                    properties,
                    selectorName: "screenID"
                ),
                let isIntegrated = simulatorBooleanProperty(
                    properties,
                    selectorName: "isDefault"
                ) ?? simulatorUnsignedLongLongProperty(
                    properties,
                    selectorName: "screenType"
                ).map({ $0 == 0 })
            else {
                // HID events target the built-in display. Rendering an unidentified
                // surface could show a different screen than the one receiving input.
                integratedDisplay = nil
                return false
            }
            candidates.append((descriptor, surface, screenID, isIntegrated, properties))
        }
        // Current SimulatorKit marks the built-in display with isDefault;
        // older releases use SimScreenType.integrated (raw value zero).
        // Require one integrated screen identity, then choose its largest plane.
        let integratedScreenIDs = Set(
            candidates.lazy.filter(\.isIntegrated).map(\.screenID)
        )
        guard integratedScreenIDs.count == 1,
              let primaryScreenID = integratedScreenIDs.first,
              let best = candidates
                .filter({ $0.screenID == primaryScreenID })
                .max(by: {
                    IOSurfaceGetWidth($0.surface) * IOSurfaceGetHeight($0.surface)
                        < IOSurfaceGetWidth($1.surface) * IOSurfaceGetHeight($1.surface)
                }) else {
            integratedDisplay = nil
            return false
        }
        integratedDisplay = (best.descriptor, best.properties)
        return true
    }

    private func simulatorBooleanProperty(
        _ target: NSObject,
        selectorName: String
    ) -> Bool? {
        let selector = NSSelectorFromString(selectorName)
        guard target.responds(to: selector),
              let messageSend = simulatorObjectiveCMessageSend()
        else { return nil }
        switch simulatorScalarReturnEncoding(target, selector: selector) {
        case "B":
            typealias Function = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(messageSend, to: Function.self)(
                target,
                selector
            )
        case "c":
            typealias Function = @convention(c) (AnyObject, Selector) -> CChar
            return unsafeBitCast(messageSend, to: Function.self)(
                target,
                selector
            ) != 0
        case nil:
            // Fast-forwarding proxies can advertise a selector without publishing
            // its method signature. The selector contract still defines BOOL.
            typealias Function = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(messageSend, to: Function.self)(target, selector)
        default:
            return nil
        }
    }

}

private func simulatorUnsignedLongLongProperty(
    _ target: NSObject,
    selectorName: String
) -> UInt64? {
    let selector = NSSelectorFromString(selectorName)
    guard target.responds(to: selector),
          let messageSend = simulatorObjectiveCMessageSend(),
          ["Q", nil].contains(simulatorScalarReturnEncoding(target, selector: selector))
    else { return nil }
    typealias Function = @convention(c) (AnyObject, Selector) -> UInt64
    return unsafeBitCast(messageSend, to: Function.self)(
        target,
        selector
    )
}

private func hasSimulatorFramebufferSurface(_ descriptor: NSObject) -> Bool {
    ["framebufferSurface", "ioSurface"].contains {
        descriptor.responds(to: NSSelectorFromString($0))
    }
}

private func simulatorFramebufferSurface(_ descriptor: NSObject) -> AnyObject? {
    objectProperty(descriptor, selectorName: "framebufferSurface")
        ?? objectProperty(descriptor, selectorName: "ioSurface")
}

private func simulatorUnsignedIntegerProperty(
    _ target: NSObject,
    selectorName: String
) -> UInt32? {
    let selector = NSSelectorFromString(selectorName)
    guard target.responds(to: selector),
          let messageSend = simulatorObjectiveCMessageSend(),
          ["I", nil].contains(simulatorScalarReturnEncoding(target, selector: selector))
    else { return nil }
    typealias Function = @convention(c) (AnyObject, Selector) -> UInt32
    return unsafeBitCast(messageSend, to: Function.self)(
        target,
        selector
    )
}

private func simulatorScalarReturnEncoding(
    _ target: NSObject,
    selector: Selector
) -> String? {
    if let method = class_getInstanceMethod(type(of: target), selector) {
        let returnType = method_copyReturnType(method)
        defer { free(returnType) }
        return String(cString: returnType)
    }
    guard let messageSend = simulatorObjectiveCMessageSend() else { return nil }
    let signatureSelector = NSSelectorFromString("methodSignatureForSelector:")
    typealias SignatureFunction =
        @convention(c) (AnyObject, Selector, Selector) -> AnyObject?
    guard let signature = unsafeBitCast(messageSend, to: SignatureFunction.self)(
        target,
        signatureSelector,
        selector
    ) as? NSObject else { return nil }
    let returnTypeSelector = NSSelectorFromString("methodReturnType")
    typealias ReturnTypeFunction =
        @convention(c) (AnyObject, Selector) -> UnsafePointer<CChar>?
    guard let returnType = unsafeBitCast(messageSend, to: ReturnTypeFunction.self)(
        signature,
        returnTypeSelector
    ) else { return nil }
    return String(cString: returnType)
}

private func simulatorObjectiveCMessageSend() -> UnsafeMutableRawPointer? {
    dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend")
}

@discardableResult
private func invokeVoid(_ target: NSObject, selectorName: String) -> Bool {
    let selector = NSSelectorFromString(selectorName)
    guard target.responds(to: selector) else { return false }
    target.perform(selector)
    return true
}

private func sendFiveObjectMessage(
    _ target: AnyObject,
    _ selector: Selector,
    _ first: AnyObject,
    _ second: AnyObject,
    _ third: AnyObject,
    _ fourth: AnyObject,
    _ fifth: AnyObject
) -> Bool {
    guard
        let messageSend = dlsym(
            UnsafeMutableRawPointer(bitPattern: -2),
            "objc_msgSend"
        )
    else {
        return false
    }
    typealias Function =
        @convention(c) (
            AnyObject,
            Selector,
            AnyObject,
            AnyObject,
            AnyObject,
            AnyObject,
            AnyObject
        ) -> Void
    unsafeBitCast(messageSend, to: Function.self)(
        target,
        selector,
        first,
        second,
        third,
        fourth,
        fifth
    )
    return true
}
