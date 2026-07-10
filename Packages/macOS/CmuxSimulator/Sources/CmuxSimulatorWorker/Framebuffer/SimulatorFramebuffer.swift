import CmuxSimulator
import Darwin
import Foundation
import IOSurface
import ObjectiveC.runtime
import QuartzCore

/// Direct SimulatorKit framebuffer attachment.
///
/// The descriptor discovery and callback contract are adapted from serve-sim
/// (Apache-2.0, Evan Bacon) and Baguette (Apache-2.0, tddworks). This worker
/// keeps every descriptor and IOSurface reference out of the cmux process.
@MainActor
final class SimulatorFramebuffer {
    private let callbackQueue = DispatchQueue.main
    private let renderContext: SimulatorRemoteRenderContext
    private let onDisplayChange: @MainActor (SimulatorDisplayMetadata) -> Void

    private var descriptors: [NSObject] = []
    private var callbackIdentifiers: [ObjectIdentifier: NSUUID] = [:]
    private var ioClient: NSObject?
    private var displayLayer: CALayer?
    private var highlightLayer: CALayer?
    private var highlightedFrame: SimulatorRect?
    private var accessibilityCoordinateSpace: SimulatorRect?
    private var retainedSurface: IOSurface?
    private var orientationState = SimulatorFramebufferOrientationState()
    private var nativeOrientationRawValue: UInt32?
    private var displayScale = 1.0
    private var lastPublishedMetadata: SimulatorDisplayMetadata?

    init(
        renderContext: SimulatorRemoteRenderContext,
        onDisplayChange: @escaping @MainActor (SimulatorDisplayMetadata) -> Void
    ) {
        self.renderContext = renderContext
        self.onDisplayChange = onDisplayChange
    }

    deinit {
        MainActor.assumeIsolated {
            stop()
        }
    }

    func start(device: NSObject) throws {
        stop()
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
    }

    func stop() {
        lastPublishedMetadata = nil
        orientationState.reset()
        nativeOrientationRawValue = nil
        unregisterCallbacks()
        descriptors.removeAll()
        callbackIdentifiers.removeAll()
        ioClient = nil
        retainedSurface = nil
        displayLayer?.removeFromSuperlayer()
        displayLayer = nil
        highlightLayer = nil
        highlightedFrame = nil
        accessibilityCoordinateSpace = nil
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
        let ports = objectProperty(ioClient, selectorName: "ioPorts") as? [NSObject]
            ?? objectProperty(ioClient, selectorName: "deviceIOPorts") as? [NSObject]
        guard let ports else {
            throw SimulatorWorkerFailure.framebufferUnavailable("SimulatorKit did not publish device I/O ports.")
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

    func resize(_ geometry: SimulatorSurfaceGeometry) {
        renderContext.resize(geometry)
        layoutDisplayLayer()
    }

    @discardableResult
    func setAccessibilityHighlight(_ frame: SimulatorRect?) -> Bool {
        highlightedFrame = frame
        guard let frame else {
            highlightLayer?.removeFromSuperlayer()
            highlightLayer = nil
            CATransaction.flush()
            return true
        }
        guard frame.width.isFinite, frame.height.isFinite,
              frame.x.isFinite, frame.y.isFinite,
              frame.width > 0, frame.height > 0,
              displayLayer != nil, accessibilityCoordinateSpace != nil
        else {
            return false
        }
        if highlightLayer == nil {
            let layer = CALayer()
            layer.borderColor = CGColor(red: 1, green: 0.45, blue: 0.05, alpha: 1)
            layer.backgroundColor = CGColor(red: 1, green: 0.45, blue: 0.05, alpha: 0.16)
            layer.borderWidth = 2
            displayLayer?.addSublayer(layer)
            highlightLayer = layer
        }
        layoutHighlightLayer()
        CATransaction.flush()
        return true
    }

    func setAccessibilityCoordinateSpace(_ frame: SimulatorRect?) {
        guard let frame,
              frame.x.isFinite, frame.y.isFinite,
              frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, frame.height > 0
        else {
            accessibilityCoordinateSpace = nil
            return
        }
        accessibilityCoordinateSpace = frame
        layoutHighlightLayer()
    }

    private func registerCallbacks(on descriptor: NSObject) throws {
        let selector = NSSelectorFromString(
            "registerScreenCallbacksWithUUID:callbackQueue:frameCallback:" +
                "surfacesChangedCallback:propertiesChangedCallback:"
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
        let propertiesChangedCallback: @convention(block) () -> Void = { @MainActor [weak self, weak descriptor] in
            guard let descriptor else { return }
            self?.handleDisplayPropertiesChange(descriptor)
        }

        guard sendFiveObjectMessage(
            descriptor,
            selector,
            identifier,
            callbackQueue,
            frameCallback as AnyObject,
            surfacesChangedCallback as AnyObject,
            propertiesChangedCallback as AnyObject
        ) else {
            throw SimulatorWorkerFailure.framebufferUnavailable(
                "Objective-C message dispatch is unavailable for framebuffer callbacks."
            )
        }
    }

    private func handleSurfaceTopologyChange() {
        if publishLatest(readNativeOrientation: true) { return }
        // A surface-change callback is the synchronization signal that the
        // old descriptor became stale. Re-enumerate once for that event.
        try? wireFramebuffer()
        _ = publishLatest(readNativeOrientation: true)
    }

    private func handleDisplayPropertiesChange(_ descriptor: NSObject) {
        guard let properties = objectProperty(
                  descriptor,
                  selectorName: "screenProperties"
              ) as? NSObject,
              let rawValue = simulatorUnsignedIntegerProperty(
                  properties,
                  selectorName: "uiOrientation"
              ),
              simulatorNativeOrientation(
                  rawValue: rawValue
              ) != nil
        else {
            _ = publishLatest()
            return
        }
        nativeOrientationRawValue = rawValue
        _ = publishLatest(nativeOrientationIsAuthoritative: true)
    }

    @discardableResult
    private func publishLatest(
        readNativeOrientation: Bool = false,
        nativeOrientationIsAuthoritative: Bool = false
    ) -> Bool {
        guard let display = bestDisplay(readNativeOrientation: readNativeOrientation) else {
            return false
        }
        if let rawValue = display.orientationRawValue,
           simulatorNativeOrientation(rawValue: rawValue) != nil {
            nativeOrientationRawValue = rawValue
        }
        let surface = display.surface
        retainedSurface = surface
        let width = IOSurfaceGetWidth(surface)
        let height = IOSurfaceGetHeight(surface)
        guard width > 0, height > 0 else { return false }

        let layer: CALayer
        if let displayLayer {
            layer = displayLayer
        } else {
            layer = CALayer()
            layer.masksToBounds = true
            layer.contentsGravity = .resizeAspect
            renderContext.rootLayer.addSublayer(layer)
            displayLayer = layer
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Core Animation accepts IOSurface as layer contents and carries the
        // shared surface through the remote context without an encode/decode.
        layer.contents = surface
        layer.contentsScale = displayScale
        CATransaction.commit()
        layoutDisplayLayer()
        CATransaction.flush()

        let orientation = orientationState.observe(
            width: width,
            height: height,
            nativeRawValue: nativeOrientationRawValue,
            nativeValueIsAuthoritative: nativeOrientationIsAuthoritative
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

    private func layoutDisplayLayer() {
        guard let layer = displayLayer, let retainedSurface else { return }
        let bounds = renderContext.rootLayer.bounds
        let width = CGFloat(IOSurfaceGetWidth(retainedSurface))
        let height = CGFloat(IOSurfaceGetHeight(retainedSurface))
        guard bounds.width > 0, bounds.height > 0, width > 0, height > 0 else { return }

        let scale = min(bounds.width / width, bounds.height / height)
        let size = CGSize(width: width * scale, height: height * scale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.bounds = CGRect(origin: .zero, size: size)
        layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
        layoutHighlightLayer()
    }

    private func layoutHighlightLayer() {
        guard let highlightedFrame, let highlightLayer, let displayLayer,
              let accessibilityCoordinateSpace
        else {
            return
        }
        let bounds = displayLayer.bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlightLayer.frame = simulatorAccessibilityHighlightFrame(
            highlightedFrame,
            coordinateSpace: accessibilityCoordinateSpace,
            displayBounds: bounds
        )
        CATransaction.commit()
    }

    private func bestDisplay(
        readNativeOrientation: Bool
    ) -> (surface: IOSurface, orientationRawValue: UInt32?)? {
        var best: IOSurface?
        var bestOrientationRawValue: UInt32?
        var bestArea = 0
        for descriptor in descriptors {
            guard let rawSurface = simulatorFramebufferSurface(descriptor) else {
                continue
            }
            guard let surface = rawSurface as? IOSurface else { continue }
            let area = IOSurfaceGetWidth(surface) * IOSurfaceGetHeight(surface)
            if area > bestArea {
                best = surface
                if readNativeOrientation {
                    let properties = objectProperty(
                        descriptor,
                        selectorName: "screenProperties"
                    ) as? NSObject
                    bestOrientationRawValue = properties.flatMap {
                        simulatorUnsignedIntegerProperty($0, selectorName: "uiOrientation")
                    }
                }
                bestArea = area
            }
        }
        return best.map { ($0, bestOrientationRawValue) }
    }

}

func simulatorAccessibilityHighlightFrame(
    _ frame: SimulatorRect,
    coordinateSpace: SimulatorRect,
    displayBounds: CGRect
) -> CGRect {
    let relativeX = frame.x - coordinateSpace.x
    let relativeY = frame.y - coordinateSpace.y
    let x = displayBounds.minX
        + relativeX / coordinateSpace.width * displayBounds.width
    let width = frame.width / coordinateSpace.width * displayBounds.width
    let height = frame.height / coordinateSpace.height * displayBounds.height
    // AXP frames use a top-left origin. Core Animation layer geometry uses
    // a bottom-left origin, so flip the complete vertical extent.
    let y = displayBounds.maxY
        - ((relativeY + frame.height) / coordinateSpace.height * displayBounds.height)
    return CGRect(x: x, y: y, width: width, height: height)
        .intersection(displayBounds)
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
          let method = class_getInstanceMethod(type(of: target), selector)
    else {
        return nil
    }
    let returnType = method_copyReturnType(method)
    defer { free(returnType) }
    guard String(cString: returnType) == "I" else { return nil }
    typealias Function = @convention(c) (AnyObject, Selector) -> UInt32
    return unsafeBitCast(method_getImplementation(method), to: Function.self)(
        target,
        selector
    )
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
    guard let messageSend = dlsym(
        UnsafeMutableRawPointer(bitPattern: -2),
        "objc_msgSend"
    ) else {
        return false
    }
    typealias Function = @convention(c) (
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
