import CoreGraphics
import Darwin
import Foundation
import XPC

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
        case indigo(client: NSObject)
    }

    private static let service = "com.apple.coredevice.feature.remote.hid.digitizer"
    /// The Indigo button event source of Simulator's Toggle Software Keyboard (classic cmux's worker sent the same).
    private static let softwareKeyboardSource: Int32 = 0x3F0
    private let path: Path
    private let device: NSObject
    private let builders: IndigoBuilders
    /// The legacy Indigo client the software keyboard toggle needs on the dtuhid path, opened on first use.
    private var keyboardClient: NSObject?

    init(device: NSObject, runtime: SimulatorKitRuntime) throws {
        self.device = device
        builders = IndigoBuilders(runtime)
        if let connection = Self.dtuhid(device, runtime: runtime) {
            path = .dtuhid(connection)
            return
        }
        guard let client = Self.legacyClient(device) else {
            throw PhoneError.unsupported(mode: .simulator, what: "touch input with this Xcode")
        }
        path = .indigo(client: client)
    }

    /// Closes the XPC connection (the simulator rebooted or the transport is replaced).
    func close() {
        if case .dtuhid(let connection) = path { xpc_connection_cancel(connection) }
    }

    func touch(_ phase: PhoneTouch.Phase, x: Double, y: Double) throws {
        switch path {
        case .dtuhid:
            send("IndigoDigitizerEvent", [
                ("pointOne", .dictionary([("x", .double(x)), ("y", .double(y))])),
                ("eventType", .uint64(phase == .began ? 0 : phase == .moved ? 1 : 2)),
                ("edge", .uint64(0)),
                ("target", .uint64(0)),
            ])
        case .indigo:
            guard let mouse = builders.mouse else { throw PhoneError.unsupported(mode: .simulator, what: "touch input with this Xcode") }
            try sendIndigo(mouse(CGPoint(x: x, y: y), phase == .ended))
        }
    }

    func key(_ usage: UInt32, down: Bool) throws {
        switch path {
        case .dtuhid:
            send("IndigoKeyboardButtonEvent", [("usageCode", .uint64(UInt64(usage))), ("state", .uint64(down ? 1 : 2))])
        case .indigo:
            guard let keyboard = builders.keyboard else { throw PhoneError.unsupported(mode: .simulator, what: "typing with this Xcode") }
            try sendIndigo(keyboard(usage, down))
        }
    }

    func button(page: UInt32, usage: UInt32, down: Bool) throws {
        switch path {
        case .dtuhid:
            send("IndigoButtonEvent", [
                ("usagePage", .uint64(UInt64(page))),
                ("usageCode", .uint64(UInt64(usage))),
                ("state", .uint64(down ? 1 : 2)),
            ])
        case .indigo:
            // Home, lock and Siri are Indigo "event sources" on the legacy path; volume is arbitrary HID.
            let source: Int32? = switch (page, usage) {
            case (0x0C, 0x40): 0
            case (0x0C, 0x30): 1
            case (0x0C, 0xCF): 0x400002
            default: nil
            }
            if let source, let button = builders.button {
                try sendIndigo(button(source, down))
            } else if let arbitrary = builders.arbitrary {
                try sendIndigo(arbitrary(page, usage, down))
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
        case .indigo(let legacy): client = legacy
        case .dtuhid:
            guard let opened = keyboardClient ?? Self.legacyClient(device) else {
                throw PhoneError.unsupported(mode: .simulator, what: "the software keyboard with this Xcode")
            }
            keyboardClient = opened
            client = opened
        }
        guard let button = builders.button else {
            throw PhoneError.unsupported(mode: .simulator, what: "the software keyboard with this Xcode")
        }
        try sendIndigo(button(Self.softwareKeyboardSource, true), via: client)
        try sendIndigo(button(Self.softwareKeyboardSource, false), via: client)
    }

    private func send(_ type: String, _ payload: [(String, XPCValue)]) {
        guard case .dtuhid(let connection) = path else { return }
        let message = XPCValue.xpcDictionary([
            ("messageType", .string(type)),
            ("isBarrier", .bool(false)),
            ("featureIdentifier", .string(Self.service)),
            ("payload", .dictionary(payload)),
        ])
        xpc_connection_send_message(connection, message)
    }

    private func sendIndigo(_ message: consuming IndigoMessage) throws {
        guard case .indigo(let client) = path else {
            // `message` is freed as it goes out of scope.
            throw PhoneError.unsupported(mode: .simulator, what: "input with this Xcode")
        }
        try sendIndigo(message, via: client)
    }

    private typealias SendMessage = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer, ObjCBool, AnyObject?, AnyObject?) -> Void

    /// Hands `message` to SimulatorKit, which frees it once sent (`freeWhenDone`). On every
    /// path that throws, `message` is freed as it goes out of scope.
    private func sendIndigo(_ message: consuming IndigoMessage, via client: NSObject) throws {
        guard let method = PrivateMethod(client, "sendWithMessage:freeWhenDone:completionQueue:completion:"),
              // SAFETY: only resolves the function; see the call below.
              let handOver = unsafe method.function(SendMessage.self, returns: .void,
                                                    arguments: [.pointer, .integer(bytes: 1), .object, .object]) else {
            throw PhoneError.unsupported(mode: .simulator, what: "input with this Xcode")
        }
        // SAFETY: handOff gives up this side's ownership of the malloc'd message (or nil).
        guard let bytes = unsafe message.handOff() else {
            throw PhoneError.unsupported(mode: .simulator, what: "input with this Xcode")
        }
        // SAFETY: `bytes` is a malloc'd Indigo message nobody else owns; freeWhenDone YES hands
        // it to SimulatorKit, which frees it once sent, and this side never touches it again.
        // There is no completion queue or block.
        unsafe handOver(client, method.selector, bytes, ObjCBool(true), nil, nil)
    }

    private typealias Lookup = @convention(c) (AnyObject, Selector, NSString, AutoreleasingUnsafeMutablePointer<NSError?>) -> mach_port_t
    private typealias Endpoint = @convention(c) (mach_port_t, UInt64, UInt64) -> xpc_object_t?
    private typealias Connect = @convention(c) (xpc_object_t) -> xpc_connection_t?
    private typealias Enable = @convention(c) (xpc_connection_t) -> Void

    /// Xcode 27: look up the guest's HID service port and open an XPC connection to it.
    private static func dtuhid(_ device: NSObject, runtime: SimulatorKitRuntime) -> xpc_connection_t? {
        guard let method = PrivateMethod(device, "lookup:error:"),
              // SAFETY: only resolves the function; see the call below.
              let lookup = unsafe method.function(Lookup.self, returns: .integer(bytes: 4), arguments: [.object, .pointer]),
              let endpoint = runtime.function("xpc_endpoint_create_mach_port_4sim", as: Endpoint.self),
              let connect = runtime.function("xpc_connection_create_from_endpoint", as: Connect.self),
              let enable = runtime.function("xpc_connection_enable_sim2host_4sim", as: Enable.self) else { return nil }
        var error: NSError?
        // SAFETY: `error` is a local that outlives the call; lookup:error: stores at most one
        // autoreleased NSError in it (Cocoa's error convention).
        let port = unsafe lookup(device, method.selector, service as NSString, &error)
        guard port != mach_port_t(MACH_PORT_NULL),
              let made = endpoint(port, 0, 0),
              let connection = connect(made) else { return nil }
        enable(connection)
        resume(connection)
        return connection
    }

    /// Starts the connection with an event handler that ignores events. XPC calls the handler on its own
    /// queue, so it is formed here, outside the main actor. Errors surface on the next send; the tab
    /// reconnects by opening a new transport.
    nonisolated private static func resume(_ connection: xpc_connection_t) {
        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_resume(connection)
    }

    private static func legacyClient(_ device: NSObject) -> NSObject? {
        guard let cls = NSClassFromString("_TtC12SimulatorKit24SimDeviceLegacyHIDClient") as? NSObject.Type else { return nil }
        return privateInstance(of: cls, initializer: "initWithDevice:error:", device)
    }
}

/// One value of a dtuhid XPC message.
private enum XPCValue {
    case string(String)
    case double(Double)
    case uint64(UInt64)
    case bool(Bool)
    case dictionary([(String, XPCValue)])

    /// An XPC dictionary of `entries`, in order.
    static func xpcDictionary(_ entries: [(String, XPCValue)]) -> xpc_object_t {
        let dictionary = xpc_dictionary_create_empty()
        for (key, value) in entries {
            switch value {
            case .string(let text):
                // SAFETY: `key` and `text` are NUL-terminated copies Swift keeps alive for the
                // call; XPC copies both.
                unsafe xpc_dictionary_set_string(dictionary, key, text)
            case .double(let number):
                // SAFETY: `key` is a NUL-terminated copy Swift keeps alive for the call; XPC copies it.
                unsafe xpc_dictionary_set_double(dictionary, key, number)
            case .uint64(let number):
                // SAFETY: as for .double.
                unsafe xpc_dictionary_set_uint64(dictionary, key, number)
            case .bool(let flag):
                // SAFETY: as for .double.
                unsafe xpc_dictionary_set_bool(dictionary, key, flag)
            case .dictionary(let nested):
                // SAFETY: as for .double; XPC retains the nested dictionary.
                unsafe xpc_dictionary_set_value(dictionary, key, Self.xpcDictionary(nested))
            }
        }
        return dictionary
    }
}
