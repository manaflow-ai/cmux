import CmuxSimulator
import CoreGraphics
import Darwin.Mach
import Foundation
import ObjectiveC.runtime

/// SimulatorKit HID transport isolated inside the worker process.
///
/// The runtime symbols, ABI signatures, and button codes are adapted from
/// serve-sim (Apache-2.0, Evan Bacon), Baguette (Apache-2.0, tddworks), and
/// idb (MIT, Meta Platforms). Every symbol is probed before use so an Xcode
/// update disables a capability instead of invoking a missing entry point.
@MainActor
final class SimulatorHIDTransport {
    private typealias MouseFunction = @convention(c) (
        UnsafePointer<CGPoint>,
        UnsafePointer<CGPoint>?,
        UInt32,
        Int32,
        CGFloat,
        CGFloat,
        UInt32
    ) -> UnsafeMutableRawPointer?
    private typealias LegacyButtonFunction = @convention(c) (
        Int32,
        Int32,
        Int32
    ) -> UnsafeMutableRawPointer?
    private typealias ArbitraryHIDFunction = @convention(c) (
        UInt32,
        UInt32,
        UInt32,
        UInt32
    ) -> UnsafeMutableRawPointer?
    private typealias KeyboardFunction = @convention(c) (
        UInt32,
        UInt32
    ) -> UnsafeMutableRawPointer?
    private typealias DigitalCrownFunction = @convention(c) (
        Double
    ) -> UnsafeMutableRawPointer?

    private static let digitizerTarget: UInt32 = 0x32
    private static let hardwareButtonTarget: Int32 = 0x33
    private static let keyDown: UInt32 = 1
    private static let keyUp: UInt32 = 2

    private let frameworkLoader: SimulatorFrameworkLoader
    let sleeper: any SimulatorHIDSleeping
    let pointerSenderOverride: (@MainActor (SimulatorPointerEvent) -> Bool)?
    let keySenderOverride: (@MainActor (SimulatorKeyEvent) -> Bool)?
    let convenienceSenderOverride: (@MainActor (SimulatorConvenienceButton, Bool) -> Bool)?
    let transmissionDrainerOverride: (@MainActor () async -> Bool)?
    var device: NSObject?
    private var client: NSObject?
    var modernTransport: SimulatorDTUHIDTransport?
    private var sendSelector: Selector?
    private var mouseFunction: MouseFunction?
    private var legacyButtonFunction: LegacyButtonFunction?
    private var arbitraryHIDFunction: ArbitraryHIDFunction?
    private var keyboardFunction: KeyboardFunction?
    private var digitalCrownFunction: DigitalCrownFunction?
    var lastPointerEvent: SimulatorPointerEvent?
    var heldKeys: Set<UInt32> = []
    var heldButtons = SimulatorHeldHIDButtonState()
    var heldConvenienceButtons: Set<SimulatorConvenienceButton> = []

    init(
        frameworkLoader: SimulatorFrameworkLoader,
        sleeper: any SimulatorHIDSleeping = ContinuousSimulatorHIDSleeper(),
        pointerSenderOverride: (@MainActor (SimulatorPointerEvent) -> Bool)? = nil,
        keySenderOverride: (@MainActor (SimulatorKeyEvent) -> Bool)? = nil,
        convenienceSenderOverride: (@MainActor (SimulatorConvenienceButton, Bool) -> Bool)? = nil,
        transmissionDrainerOverride: (@MainActor () async -> Bool)? = nil
    ) {
        self.frameworkLoader = frameworkLoader
        self.sleeper = sleeper
        self.pointerSenderOverride = pointerSenderOverride
        self.keySenderOverride = keySenderOverride
        self.convenienceSenderOverride = convenienceSenderOverride
        self.transmissionDrainerOverride = transmissionDrainerOverride
    }

    deinit {
        _ = MainActor.assumeIsolated {
            releaseInputs()
        }
    }

    func attach(device: NSObject) throws {
        guard releaseInputs() else {
            throw SimulatorWorkerFailure.inputUnavailable(
                "The previous Simulator input session could not release all held input."
            )
        }
        self.device = device
        resolveFunctions()
        modernTransport = try? SimulatorDTUHIDTransport(device: device)

        var legacyError: Error?
        if mouseFunction != nil || legacyButtonFunction != nil || keyboardFunction != nil {
            do {
                client = try makeClient(device: device)
                sendSelector = NSSelectorFromString(
                    "sendWithMessage:freeWhenDone:completionQueue:completion:"
                )
            } catch {
                legacyError = error
                client = nil
                sendSelector = nil
            }
        }
        guard modernTransport != nil || client != nil else {
            throw legacyError ?? SimulatorWorkerFailure.inputUnavailable(
                "Neither the SimulatorKit Indigo transport nor the DTUHID transport is available."
            )
        }
    }

    func capabilities(
        framebufferAvailable: Bool,
        accessibilityAvailable: Bool,
        cameraAvailable: Bool
    ) -> SimulatorWorkerCapabilityProbe {
        let device = device
        return SimulatorWorkerCapabilityProbe(
            hasFramebuffer: framebufferAvailable,
            hasTouch: modernTransport != nil || (mouseFunction != nil && client != nil),
            hasKeyboard: modernTransport != nil || (keyboardFunction != nil && client != nil),
            hasLegacyButtons: modernTransport != nil || (legacyButtonFunction != nil && client != nil),
            hasArbitraryButtons: modernTransport != nil || (arbitraryHIDFunction != nil && client != nil),
            hasRotation: device?.responds(to: NSSelectorFromString("lookup:error:")) == true,
            hasDigitalCrown: digitalCrownFunction != nil && client != nil,
            hasMemoryWarning: device?.responds(to: NSSelectorFromString("simulateMemoryWarning")) == true,
            hasCoreAnimationDiagnostics: device?.responds(
                to: NSSelectorFromString("setCADebugOption:enabled:")
            ) == true,
            hasAccessibility: accessibilityAvailable,
            hasForegroundApplication: accessibilityAvailable,
            hasCameraInjection: cameraAvailable
        )
    }

    @discardableResult
    func send(_ event: SimulatorPointerEvent) -> Bool {
        guard Self.isNormalized(event.primary),
              event.secondary.map(Self.isNormalized) ?? true else { return false }
        if let pointerSenderOverride {
            let result = pointerSenderOverride(event)
            if result {
                updatePointerState(after: event)
            }
            return result
        }
        if let modernTransport {
            let result = modernTransport.send(event)
            if result {
                updatePointerState(after: event)
            }
            return result
        }
        guard let mouseFunction else { return false }
        let eventType: Int32 = switch event.phase {
        case .began, .moved: 1
        case .ended, .cancelled: 2
        }

        var primary = CGPoint(x: event.primary.x, y: event.primary.y)
        let rawMessage: UnsafeMutableRawPointer?
        if let secondary = event.secondary {
            var secondaryPoint = CGPoint(x: secondary.x, y: secondary.y)
            rawMessage = withUnsafePointer(to: &primary) { primaryPointer in
                withUnsafePointer(to: &secondaryPoint) { secondaryPointer in
                    mouseFunction(
                        primaryPointer,
                        secondaryPointer,
                        Self.digitizerTarget,
                        eventType,
                        1,
                        1,
                        event.edge.rawValue
                    )
                }
            }
        } else {
            rawMessage = withUnsafePointer(to: &primary) { primaryPointer in
                mouseFunction(
                    primaryPointer,
                    nil,
                    Self.digitizerTarget,
                    eventType,
                    1,
                    1,
                    event.edge.rawValue
                )
            }
        }
        guard let rawMessage, send(rawMessage) else { return false }
        updatePointerState(after: event)
        return true
    }

    private static func isNormalized(_ point: SimulatorPoint) -> Bool {
        point.x.isFinite && point.y.isFinite
            && (0...1).contains(point.x) && (0...1).contains(point.y)
    }

    @discardableResult
    func send(_ event: SimulatorKeyEvent) -> Bool {
        let sent: Bool
        if let keySenderOverride {
            sent = keySenderOverride(event)
        } else if let modernTransport {
            sent = modernTransport.send(event)
        } else {
            guard let keyboardFunction else { return false }
            let direction = event.phase == .down ? Self.keyDown : Self.keyUp
            guard let rawMessage = keyboardFunction(event.usage, direction) else {
                return false
            }
            sent = send(rawMessage)
        }
        guard sent else { return false }
        updateKeyState(after: event)
        return true
    }

    func sendAndWait(_ event: SimulatorKeyEvent) async -> Bool {
        let sent: Bool
        if let keySenderOverride {
            sent = keySenderOverride(event)
        } else if let modernTransport {
            // DTUHID only confirms that XPC accepted the send locally. The
            // caller paces events and reports transmission, not guest receipt.
            sent = modernTransport.send(event)
        } else {
            guard let keyboardFunction else { return false }
            let direction = event.phase == .down ? Self.keyDown : Self.keyUp
            guard let rawMessage = keyboardFunction(event.usage, direction) else { return false }
            sent = await sendAndWait(rawMessage)
        }
        guard sent else { return false }
        updateKeyState(after: event)
        return true
    }

    func releaseHeldKeysAndWait() async {
        for usage in heldKeys.sorted() {
            _ = await sendAndWait(SimulatorKeyEvent(usage: usage, phase: .up))
        }
    }

    private func updateKeyState(after event: SimulatorKeyEvent) {
        switch event.phase {
        case .down:
            heldKeys.insert(event.usage)
        case .up:
            heldKeys.remove(event.usage)
        }
    }

    @discardableResult
    func sendDigitalCrown(_ delta: Double) -> Bool {
        guard delta.isFinite, delta != 0,
              let digitalCrownFunction,
              let rawMessage = digitalCrownFunction(delta)
        else {
            return false
        }
        return send(rawMessage)
    }

    private func resolveFunctions() {
        if let symbol = frameworkLoader.symbol(named: "IndigoHIDMessageForMouseNSEvent") {
            mouseFunction = unsafeBitCast(symbol, to: MouseFunction.self)
        }
        if let symbol = frameworkLoader.symbol(named: "IndigoHIDMessageForButton") {
            legacyButtonFunction = unsafeBitCast(symbol, to: LegacyButtonFunction.self)
        }
        if let symbol = frameworkLoader.symbol(named: "IndigoHIDMessageForHIDArbitrary") {
            arbitraryHIDFunction = unsafeBitCast(symbol, to: ArbitraryHIDFunction.self)
        }
        if let symbol = frameworkLoader.symbol(named: "IndigoHIDMessageForKeyboardArbitrary") {
            keyboardFunction = unsafeBitCast(symbol, to: KeyboardFunction.self)
        }
        if let symbol = frameworkLoader.symbol(named: "IndigoHIDMessageForDigitalCrownEvent") {
            digitalCrownFunction = unsafeBitCast(symbol, to: DigitalCrownFunction.self)
        }
    }

    private func makeClient(device: NSObject) throws -> NSObject {
        guard let clientClass = NSClassFromString("_TtC12SimulatorKit24SimDeviceLegacyHIDClient"),
              let metaClass = object_getClass(clientClass)
        else {
            throw SimulatorWorkerFailure.inputUnavailable("SimulatorKit's legacy HID client is unavailable.")
        }

        let allocateSelector = NSSelectorFromString("alloc")
        guard let allocateImplementation = class_getMethodImplementation(metaClass, allocateSelector) else {
            throw SimulatorWorkerFailure.inputUnavailable("SimulatorKit's HID client cannot be allocated.")
        }
        typealias AllocateFunction = @convention(c) (AnyClass, Selector) -> AnyObject?
        guard let instance = unsafeBitCast(
            allocateImplementation,
            to: AllocateFunction.self
        )(clientClass, allocateSelector) else {
            throw SimulatorWorkerFailure.inputUnavailable("SimulatorKit's HID client allocation failed.")
        }

        let selector = NSSelectorFromString("initWithDevice:error:")
        guard let implementation = class_getMethodImplementation(clientClass, selector) else {
            throw SimulatorWorkerFailure.inputUnavailable("SimulatorKit's HID initializer is unavailable.")
        }
        typealias InitializeFunction = @convention(c) (
            AnyObject,
            Selector,
            AnyObject,
            AutoreleasingUnsafeMutablePointer<NSError?>
        ) -> AnyObject?
        var error: NSError?
        guard let client = unsafeBitCast(implementation, to: InitializeFunction.self)(
            instance,
            selector,
            device,
            &error
        ) as? NSObject else {
            throw SimulatorWorkerFailure.inputUnavailable(
                error?.localizedDescription ?? "SimulatorKit's HID client initialization failed."
            )
        }
        return client
    }

    private func send(_ rawMessage: UnsafeMutableRawPointer) -> Bool {
        guard let client, let sendSelector,
              let implementation = class_getMethodImplementation(type(of: client), sendSelector)
        else {
            free(rawMessage)
            return false
        }
        typealias Function = @convention(c) (
            AnyObject,
            Selector,
            UnsafeMutableRawPointer,
            ObjCBool,
            AnyObject?,
            AnyObject?
        ) -> Void
        unsafeBitCast(implementation, to: Function.self)(
            client,
            sendSelector,
            rawMessage,
            ObjCBool(true),
            nil,
            nil
        )
        return true
    }

    private func sendAndWait(_ rawMessage: UnsafeMutableRawPointer) async -> Bool {
        guard let client, let sendSelector,
              let implementation = class_getMethodImplementation(type(of: client), sendSelector)
        else {
            free(rawMessage)
            return false
        }
        typealias Function = @convention(c) (
            AnyObject,
            Selector,
            UnsafeMutableRawPointer,
            ObjCBool,
            AnyObject?,
            AnyObject?
        ) -> Void
        return await withCheckedContinuation { continuation in
            let completion: @convention(block) (NSError?) -> Void = { error in
                continuation.resume(returning: error == nil)
            }
            unsafeBitCast(implementation, to: Function.self)(
                client,
                sendSelector,
                rawMessage,
                ObjCBool(true),
                DispatchQueue.main,
                completion as AnyObject
            )
        }
    }

    func sendLegacyButton(eventSource: Int32, direction: Int32) -> Bool {
        guard let legacyButtonFunction,
              let message = legacyButtonFunction(
                  eventSource,
                  direction,
                  Self.hardwareButtonTarget
              )
        else {
            return false
        }
        return send(message)
    }

    func sendArbitraryHID(page: UInt32, usage: UInt32, direction: UInt32) -> Bool {
        guard let arbitraryHIDFunction,
              let message = arbitraryHIDFunction(
                  Self.digitizerTarget,
                  page,
                  usage,
                  direction
              )
        else {
            return false
        }
        return send(message)
    }

    func sendSystemGesture(endY: Double) async -> Bool {
        let edge = SimulatorEdge.bottom
        var succeeded = send(
            SimulatorPointerEvent(
                phase: .began,
                primary: SimulatorPoint(x: 0.5, y: 0.96),
                edge: edge
            )
        )
        do {
            try await sleeper.sleep(for: .milliseconds(16))
        } catch {
            _ = send(SimulatorPointerEvent(
                phase: .cancelled,
                primary: SimulatorPoint(x: 0.5, y: 0.96),
                edge: edge
            ))
            return false
        }
        for index in 1...10 {
            let ratio = Double(index) / 10
            let y = 0.96 + (endY - 0.96) * ratio
            succeeded = send(
                SimulatorPointerEvent(
                    phase: .moved,
                    primary: SimulatorPoint(x: 0.5, y: y),
                    edge: edge
                )
            ) && succeeded
            do {
                try await sleeper.sleep(for: .milliseconds(16))
            } catch {
                _ = send(SimulatorPointerEvent(
                    phase: .cancelled,
                    primary: SimulatorPoint(x: 0.5, y: y),
                    edge: edge
                ))
                return false
            }
        }
        return send(
            SimulatorPointerEvent(
                phase: .ended,
                primary: SimulatorPoint(x: 0.5, y: endY),
                edge: edge
            )
        ) && succeeded
    }

    private func updatePointerState(after event: SimulatorPointerEvent) {
        switch event.phase {
        case .began, .moved:
            lastPointerEvent = event
        case .ended, .cancelled:
            lastPointerEvent = nil
        }
    }

}
