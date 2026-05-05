import Foundation
import ObjectiveC

final class CMUXSimulatorHIDInput: @unchecked Sendable {
    private let device: NSObject
    private let simulatorKitPath: String
    private let lock = NSLock()

    private var client: AnyObject?
    private var mouseFunction: MouseFunction?
    private var buttonFunction: ButtonFunction?
    private var scrollFunction: ScrollFunction?
    private var createPointerService: ServiceFunction?
    private var createMouseService: ServiceFunction?
    private var removePointerService: ServiceFunction?

    private typealias MouseFunction = @convention(c) (
        UnsafePointer<CGPoint>,
        UnsafePointer<CGPoint>?,
        UInt32,
        UInt32,
        UInt32,
        Double,
        Double,
        Double,
        Double
    ) -> UnsafeMutableRawPointer?
    private typealias ButtonFunction = @convention(c) (UInt32, UInt32, UInt32) -> UnsafeMutableRawPointer?
    private typealias ScrollFunction = @convention(c) (UInt32, Double, Double, Double) -> UnsafeMutableRawPointer?
    private typealias ServiceFunction = @convention(c) () -> UnsafeMutableRawPointer?

    private enum Wire {
        static let touchDigitizer: UInt32 = 0x32
        static let buttonTarget: UInt32 = 0x33
        static let nsEventDown: UInt32 = 1
        static let nsEventUp: UInt32 = 2
        static let nsEventMoved: UInt32 = 5
        static let nsEventDragged: UInt32 = 6
        static let directionDown: UInt32 = 1
        static let directionMove: UInt32 = 0
        static let directionUp: UInt32 = 2
    }

    init(device: NSObject, simulatorKitPath: String) {
        self.device = device
        self.simulatorKitPath = simulatorKitPath
    }

    deinit {
        if let client, let removePointerService, let message = removePointerService() {
            send(message: message, to: client)
        }
    }

    func sendHover(at point: CMUXSimulatorPoint, size: CMUXSimulatorSize) throws -> Bool {
        try sendTouch(phase: .hover, first: point, second: nil, size: size)
    }

    func sendTouch(
        phase: CMUXSimulatorTouchPhase,
        first: CMUXSimulatorPoint,
        second: CMUXSimulatorPoint?,
        size: CMUXSimulatorSize
    ) throws -> Bool {
        guard let client = try ensureClient() else { return false }
        let event = mouseEvent(for: phase)
        return sendMouse(
            client: client,
            first: first,
            second: second,
            eventType: event.type,
            direction: event.direction,
            size: size
        )
    }

    func sendScroll(deltaX: Double, deltaY: Double) throws -> Bool {
        guard let client = try ensureClient(), let scrollFunction else { return false }
        guard let message = scrollFunction(Wire.touchDigitizer, deltaX, deltaY, 0) else { return false }
        send(message: message, to: client)
        return true
    }

    func sendButton(_ action: CMUXSimulatorHardwareAction) throws -> Bool {
        guard let client = try ensureClient(), let buttonFunction else { return false }
        guard let codes = buttonCodes(for: action) else {
            throw CMUXSimulatorError.actionUnsupported("\(action.displayName) is not supported by SimulatorKit HID.")
        }
        guard let down = buttonFunction(codes.button, Wire.directionDown, codes.target) else { return false }
        send(message: down, to: client)
        guard let up = buttonFunction(codes.button, Wire.directionUp, codes.target) else { return false }
        send(message: up, to: client)
        return true
    }

    private func mouseEvent(for phase: CMUXSimulatorTouchPhase) -> (type: UInt32, direction: UInt32) {
        switch phase {
        case .down:
            return (Wire.nsEventDown, Wire.directionDown)
        case .move:
            return (Wire.nsEventDragged, Wire.directionMove)
        case .up:
            return (Wire.nsEventUp, Wire.directionUp)
        case .hover:
            return (Wire.nsEventMoved, Wire.directionMove)
        }
    }

    private func buttonCodes(for action: CMUXSimulatorHardwareAction) -> (button: UInt32, target: UInt32)? {
        switch action {
        case .home:
            return (0x0, Wire.buttonTarget)
        case .lock:
            return (0x1, Wire.buttonTarget)
        case .volumeUp, .volumeDown, .screenshot, .rotateLeft, .rotateRight, .shake:
            return nil
        }
    }

    private func sendMouse(
        client: AnyObject,
        first: CMUXSimulatorPoint,
        second: CMUXSimulatorPoint?,
        eventType: UInt32,
        direction: UInt32,
        size: CMUXSimulatorSize
    ) -> Bool {
        guard let mouseFunction,
              size.width > 0,
              size.height > 0 else {
            return false
        }

        var firstPoint = CGPoint(
            x: clamp(first.x / size.width),
            y: clamp(first.y / size.height)
        )

        let message: UnsafeMutableRawPointer?
        if let second {
            var secondPoint = CGPoint(
                x: clamp(second.x / size.width),
                y: clamp(second.y / size.height)
            )
            message = withUnsafePointer(to: &firstPoint) { firstPointer in
                withUnsafePointer(to: &secondPoint) { secondPointer in
                    mouseFunction(
                        firstPointer,
                        secondPointer,
                        Wire.touchDigitizer,
                        eventType,
                        direction,
                        1.0,
                        1.0,
                        size.width,
                        size.height
                    )
                }
            }
        } else {
            message = withUnsafePointer(to: &firstPoint) { firstPointer in
                mouseFunction(
                    firstPointer,
                    nil,
                    Wire.touchDigitizer,
                    eventType,
                    direction,
                    1.0,
                    1.0,
                    size.width,
                    size.height
                )
            }
        }

        guard let message else { return false }
        send(message: message, to: client)
        return true
    }

    private func ensureClient() throws -> AnyObject? {
        lock.lock()
        defer { lock.unlock() }
        if let client { return client }

        resolveFunctions()
        guard mouseFunction != nil else {
            throw CMUXSimulatorError.inputUnavailable("SimulatorKit mouse HID function is unavailable.")
        }
        guard let clientClass = CMUXSimulatorRuntime.findHIDClientClass() else {
            throw CMUXSimulatorError.inputUnavailable("SimulatorKit HID client class is unavailable.")
        }

        let allocateSelector = NSSelectorFromString("alloc")
        guard let metaClass = object_getClass(clientClass),
              let allocateImplementation = class_getMethodImplementation(metaClass, allocateSelector) else {
            throw CMUXSimulatorError.inputUnavailable("SimulatorKit HID client cannot be allocated.")
        }

        typealias AllocateFunction = @convention(c) (AnyClass, Selector) -> AnyObject?
        guard let allocated = unsafeBitCast(allocateImplementation, to: AllocateFunction.self)(
            clientClass,
            allocateSelector
        ) else {
            throw CMUXSimulatorError.inputUnavailable("SimulatorKit HID client allocation failed.")
        }

        let initSelector = NSSelectorFromString("initWithDevice:error:")
        guard let initImplementation = class_getMethodImplementation(clientClass, initSelector) else {
            throw CMUXSimulatorError.inputUnavailable("SimulatorKit HID client initializer is unavailable.")
        }

        typealias InitFunction = @convention(c) (
            AnyObject,
            Selector,
            AnyObject,
            AutoreleasingUnsafeMutablePointer<NSError?>
        ) -> AnyObject?

        var error: NSError?
        guard let initialized = unsafeBitCast(initImplementation, to: InitFunction.self)(
            allocated,
            initSelector,
            device,
            &error
        ) else {
            throw CMUXSimulatorError.inputUnavailable(error?.localizedDescription ?? "SimulatorKit HID client initialization failed.")
        }

        client = initialized
        warmServices(on: initialized)
        return initialized
    }

    private func resolveFunctions() {
        guard mouseFunction == nil else { return }
        guard let handle = dlopen(simulatorKitPath, RTLD_NOW | RTLD_GLOBAL) else { return }
        mouseFunction = dlsym(handle, "IndigoHIDMessageForMouseNSEvent").map {
            unsafeBitCast($0, to: MouseFunction.self)
        }
        buttonFunction = dlsym(handle, "IndigoHIDMessageForButton").map {
            unsafeBitCast($0, to: ButtonFunction.self)
        }
        scrollFunction = dlsym(handle, "IndigoHIDMessageForScrollEvent").map {
            unsafeBitCast($0, to: ScrollFunction.self)
        }
        createPointerService = dlsym(handle, "IndigoHIDMessageToCreatePointerService").map {
            unsafeBitCast($0, to: ServiceFunction.self)
        }
        createMouseService = dlsym(handle, "IndigoHIDMessageToCreateMouseService").map {
            unsafeBitCast($0, to: ServiceFunction.self)
        }
        removePointerService = dlsym(handle, "IndigoHIDMessageToRemovePointerService").map {
            unsafeBitCast($0, to: ServiceFunction.self)
        }
    }

    private func warmServices(on client: AnyObject) {
        if let createPointerService, let message = createPointerService() {
            send(message: message, to: client)
        }
        if let createMouseService, let message = createMouseService() {
            send(message: message, to: client)
        }
    }

    private func send(message: UnsafeMutableRawPointer, to client: AnyObject) {
        let selector = NSSelectorFromString("sendWithMessage:freeWhenDone:completionQueue:completion:")
        guard let clientClass = object_getClass(client),
              let implementation = class_getMethodImplementation(clientClass, selector) else {
            return
        }
        typealias Function = @convention(c) (
            AnyObject,
            Selector,
            UnsafeMutableRawPointer,
            ObjCBool,
            AnyObject?,
            AnyObject?
        ) -> Void
        unsafeBitCast(implementation, to: Function.self)(client, selector, message, true, nil, nil)
    }

    private func clamp(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}
