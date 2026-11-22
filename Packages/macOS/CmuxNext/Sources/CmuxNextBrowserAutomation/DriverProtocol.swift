public import CmuxNextBrowser
import Foundation

/// A JSON value of the driver protocol (plans/cmux-next/browser-repl/driver-protocol.md).
public typealias DriverJSON = BrowserJSValue

/// The engine driver the browser host calls (plans/cmux-next/browser-host.md):
/// one method call of the driver protocol, and the protocol's events. The
/// host's provider bridge (`CmuxNextBrowserHost`) is the only caller; it
/// forwards `call` frames here and sends every event back as an `event` frame.
/// A later Rust driver replaces the conformer, not the bridge.
@MainActor
public protocol DriverCallHandler: AnyObject {
    /// Runs one driver method. Errors are `DriverError` with a protocol code.
    func call(method: String, params: DriverJSON) async throws(DriverError) -> DriverJSON
    /// Driver events in order (`tab.created`, `dialog.opened`, ...).
    var events: AsyncStream<DriverEvent> { get }
}

/// One driver event: its name and payload (every payload carries `targetId`).
public nonisolated struct DriverEvent: Hashable, Sendable {
    public let name: String
    public let payload: DriverJSON

    public init(name: String, payload: DriverJSON) {
        self.name = name
        self.payload = payload
    }
}

/// A driver error, `{ code, message }` on the wire.
public nonisolated struct DriverError: Error, Hashable, Sendable {
    public nonisolated enum Code: String, Hashable, Sendable {
        case notFound = "not_found"
        case stale
        case timeout
        case unsupported
        case invalid
        case closed
        /// A page exception thrown by evaluated code.
        case evaluation
    }

    public let code: Code
    public let message: String
    /// The JavaScript error's name for `evaluation` errors (`TypeError`).
    public let errorName: String?

    public init(_ code: Code, _ message: String, errorName: String? = nil) {
        self.code = code
        self.message = message
        self.errorName = errorName
    }

    /// The error as the protocol sends it.
    public var json: DriverJSON {
        var object: [String: DriverJSON] = ["code": .string(code.rawValue), "message": .string(message)]
        if let errorName { object["errorName"] = .string(errorName) }
        return .object(object)
    }
}
