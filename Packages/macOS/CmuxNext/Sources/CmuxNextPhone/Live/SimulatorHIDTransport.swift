import CoreGraphics
import Darwin
import Foundation
import ObjectiveC.runtime
@preconcurrency import XPC

/// One booted simulator's input path. Xcode 27's `dtuhidd` XPC service
/// (`com.apple.coredevice.feature.remote.hid.digitizer`) when the runtime has
/// it, else SimulatorKit's legacy Indigo HID client. Both take touch points
/// normalized to the screen (0...1).
///
/// Message shapes are classic cmux's (adapted there from idb's
/// FBSimulatorDTUHIDTransport and from serve-sim/Baguette for Indigo).
@MainActor
final class SimulatorHIDTransport {
    private enum Path {
        case dtuhid(xpc_connection_t)
        case indigo(client: NSObject, mouse: MouseFunction?, keyboard: KeyboardFunction?, arbitrary: ArbitraryFunction?, button: ButtonFunction?)
    }

    private typealias MouseFunction = @convention(c) (UnsafePointer<CGPoint>, UnsafePointer<CGPoint>?, UInt32, Int32, CGFloat, CGFloat, UInt32) -> UnsafeMutableRawPointer?
    private typealias KeyboardFunction = @convention(c) (UInt32, UInt32) -> UnsafeMutableRawPointer?
    private typealias ArbitraryFunction = @convention(c) (UInt32, UInt32, UInt32, UInt32) -> UnsafeMutableRawPointer?
    private typealias ButtonFunction = @convention(c) (Int32, Int32, Int32) -> UnsafeMutableRawPointer?

    private static let service = "com.apple.coredevice.feature.remote.hid.digitizer"
    /// The Indigo button event source of Simulator's Toggle Software Keyboard (classic cmux's worker sent the same).
    private static let softwareKeyboardSource: Int32 = 0x3F0
    private let path: Path
    private let device: NSObject
    private let legacyButton: ButtonFunction?
    /// The legacy Indigo client the software keyboard toggle needs on the dtuhid path, opened on first use.
    private var keyboardClient: NSObject?

    init(device: NSObject, runtime: SimulatorKitRuntime) throws {
        self.device = device
        legacyButton = runtime.symbol("IndigoHIDMessageForButton").map { unsafeBitCast($0, to: ButtonFunction.self) }
        if let connection = Self.dtuhid(device) {
            path = .dtuhid(connection)
            return
        }
        guard let client = Self.legacyClient(device) else {
            throw PhoneError.unsupported(mode: .simulator, what: "touch input with this Xcode")
        }
        path = .indigo(client: client,
                       mouse: runtime.symbol("IndigoHIDMessageForMouseNSEvent").map { unsafeBitCast($0, to: MouseFunction.self) },
                       keyboard: runtime.symbol("IndigoHIDMessageForKeyboardArbitrary").map { unsafeBitCast($0, to: KeyboardFunction.self) },
                       arbitrary: runtime.symbol("IndigoHIDMessageForHIDArbitrary").map { unsafeBitCast($0, to: ArbitraryFunction.self) },
                       button: runtime.symbol("IndigoHIDMessageForButton").map { unsafeBitCast($0, to: ButtonFunction.self) })
    }

    /// Closes the XPC connection (the simulator rebooted or the transport is replaced).
    func close() {
        if case .dtuhid(let connection) = path { xpc_connection_cancel(connection) }
    }

    func touch(_ phase: PhoneTouch.Phase, x: Double, y: Double) throws {
        switch path {
        case .dtuhid:
            let payload = xpc_dictionary_create(nil, nil, 0)
            let point = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_double(point, "x", x)
            xpc_dictionary_set_double(point, "y", y)
            xpc_dictionary_set_value(payload, "pointOne", point)
            xpc_dictionary_set_uint64(payload, "eventType", phase == .began ? 0 : phase == .moved ? 1 : 2)
            xpc_dictionary_set_uint64(payload, "edge", 0)
            xpc_dictionary_set_uint64(payload, "target", 0)
            try send("IndigoDigitizerEvent", payload)
        case .indigo(_, let mouse, _, _, _):
            guard let mouse else { throw PhoneError.unsupported(mode: .simulator, what: "touch input with this Xcode") }
            var point = CGPoint(x: x, y: y)
            // 0x32 is the digitizer target; 1 = down/drag, 2 = up.
            let message = withUnsafePointer(to: &point) { mouse($0, nil, 0x32, phase == .ended ? 2 : 1, 1, 1, 0) }
            try sendIndigo(message)
        }
    }

    func key(_ usage: UInt32, down: Bool) throws {
        switch path {
        case .dtuhid:
            let payload = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_uint64(payload, "usageCode", UInt64(usage))
            xpc_dictionary_set_uint64(payload, "state", down ? 1 : 2)
            try send("IndigoKeyboardButtonEvent", payload)
        case .indigo(_, _, let keyboard, _, _):
            guard let keyboard else { throw PhoneError.unsupported(mode: .simulator, what: "typing with this Xcode") }
            try sendIndigo(keyboard(usage, down ? 1 : 2))
        }
    }

    func button(page: UInt32, usage: UInt32, down: Bool) throws {
        switch path {
        case .dtuhid:
            let payload = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_uint64(payload, "usagePage", UInt64(page))
            xpc_dictionary_set_uint64(payload, "usageCode", UInt64(usage))
            xpc_dictionary_set_uint64(payload, "state", down ? 1 : 2)
            try send("IndigoButtonEvent", payload)
        case .indigo(_, _, _, let arbitrary, let button):
            // Home, lock and Siri are Indigo "event sources" on the legacy path; volume is arbitrary HID.
            let source: Int32? = switch (page, usage) {
            case (0x0C, 0x40): 0
            case (0x0C, 0x30): 1
            case (0x0C, 0xCF): 0x400002
            default: nil
            }
            if let source, let button {
                try sendIndigo(button(source, down ? 1 : 2, 0x33))
            } else if let arbitrary {
                try sendIndigo(arbitrary(0x32, page, usage, down ? 1 : 2))
            } else {
                throw PhoneError.unsupported(mode: .simulator, what: "hardware buttons with this Xcode")
            }
        }
    }

    /// Presses and releases Simulator's software keyboard toggle. It is an Indigo event source with
    /// no dtuhid usage, so the dtuhid path opens the legacy client for it.
    func toggleSoftwareKeyboard() throws {
        let client: NSObject
        switch path {
        case .indigo(let legacy, _, _, _, _): client = legacy
        case .dtuhid:
            guard let opened = keyboardClient ?? Self.legacyClient(device) else {
                throw PhoneError.unsupported(mode: .simulator, what: "the software keyboard with this Xcode")
            }
            keyboardClient = opened
            client = opened
        }
        guard let legacyButton else { throw PhoneError.unsupported(mode: .simulator, what: "the software keyboard with this Xcode") }
        try sendIndigo(legacyButton(Self.softwareKeyboardSource, 1, 0x33), via: client)
        try sendIndigo(legacyButton(Self.softwareKeyboardSource, 2, 0x33), via: client)
    }

    private func send(_ type: String, _ payload: xpc_object_t) throws {
        guard case .dtuhid(let connection) = path else { return }
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(message, "messageType", type)
        xpc_dictionary_set_bool(message, "isBarrier", false)
        xpc_dictionary_set_string(message, "featureIdentifier", Self.service)
        xpc_dictionary_set_value(message, "payload", payload)
        xpc_connection_send_message(connection, message)
    }

    private func sendIndigo(_ message: UnsafeMutableRawPointer?) throws {
        guard case .indigo(let client, _, _, _, _) = path else {
            if let message { free(message) }
            throw PhoneError.unsupported(mode: .simulator, what: "input with this Xcode")
        }
        try sendIndigo(message, via: client)
    }

    private func sendIndigo(_ message: UnsafeMutableRawPointer?, via client: NSObject) throws {
        guard let message else {
            throw PhoneError.unsupported(mode: .simulator, what: "input with this Xcode")
        }
        let selector = privateSelector("sendWithMessage:freeWhenDone:completionQueue:completion:")
        guard client.responds(to: selector), let imp = class_getMethodImplementation(type(of: client), selector) else {
            free(message)
            throw PhoneError.unsupported(mode: .simulator, what: "input with this Xcode")
        }
        typealias Function = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer, ObjCBool, AnyObject?, AnyObject?) -> Void
        unsafeBitCast(imp, to: Function.self)(client, selector, message, ObjCBool(true), nil, nil)
    }

    /// Xcode 27: look up the guest's HID service port and open an XPC connection to it.
    private static func dtuhid(_ device: NSObject) -> xpc_connection_t? {
        typealias Endpoint = @convention(c) (mach_port_t, UInt64, UInt64) -> xpc_object_t?
        typealias Connect = @convention(c) (xpc_object_t) -> xpc_connection_t?
        typealias Enable = @convention(c) (xpc_connection_t) -> Void
        let lookup = privateSelector("lookup:error:")
        // concurrency-allow: dlopen(nil) returns the main program's handle; it maps nothing
        guard let process = dlopen(nil, RTLD_NOW),
              let endpointSymbol = dlsym(process, "xpc_endpoint_create_mach_port_4sim"),
              let connectSymbol = dlsym(process, "xpc_connection_create_from_endpoint"),
              let enableSymbol = dlsym(process, "xpc_connection_enable_sim2host_4sim"),
              device.responds(to: lookup), let imp = class_getMethodImplementation(type(of: device), lookup) else { return nil }
        typealias Lookup = @convention(c) (AnyObject, Selector, NSString, AutoreleasingUnsafeMutablePointer<NSError?>) -> mach_port_t
        var error: NSError?
        let port = unsafeBitCast(imp, to: Lookup.self)(device, lookup, service as NSString, &error)
        guard port != mach_port_t(MACH_PORT_NULL),
              let endpoint = unsafeBitCast(endpointSymbol, to: Endpoint.self)(port, 0, 0),
              let connection = unsafeBitCast(connectSymbol, to: Connect.self)(endpoint) else { return nil }
        unsafeBitCast(enableSymbol, to: Enable.self)(connection)
        // Errors surface on the next send; the tab reconnects by opening a new transport.
        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_resume(connection)
        return connection
    }

    private static func legacyClient(_ device: NSObject) -> NSObject? {
        guard let cls = NSClassFromString("_TtC12SimulatorKit24SimDeviceLegacyHIDClient") as? NSObject.Type else { return nil }
        let initializer = privateSelector("initWithDevice:error:")
        let instance = cls.perform(privateSelector("alloc"))?.takeUnretainedValue() as? NSObject
        guard let instance, instance.responds(to: initializer),
              let imp = class_getMethodImplementation(cls, initializer) else { return nil }
        typealias Function = @convention(c) (AnyObject, Selector, AnyObject, AutoreleasingUnsafeMutablePointer<NSError?>) -> Unmanaged<AnyObject>?
        var error: NSError?
        return unsafeBitCast(imp, to: Function.self)(instance, initializer, device, &error)?.takeRetainedValue() as? NSObject
    }
}
