import Foundation

/// A driver error with a protocol code (`not_found`, `stale`, `timeout`,
/// `unsupported`, `invalid`, `closed`).
public struct BrowserReplDriverError: Error, Equatable, Sendable {
    public let code: String
    public let message: String
    /// `Error.name` of a page exception (`TypeError`, ...), when there was one.
    public let errorName: String?

    public init(code: String, message: String, errorName: String? = nil) {
        self.code = code
        self.message = message
        self.errorName = errorName
    }

    /// The JSON object sent to the runtime: `{ code, message, errorName? }`.
    public var json: String {
        var object: [String: Any] = ["code": code, "message": message]
        if let errorName { object["errorName"] = errorName }
        return BrowserReplJSON.encode(object) ?? #"{"code":"invalid","message":"error"}"#
    }
}

/// Receives driver events (`tab.created`, `dialog.opened`, ...).
public typealias BrowserReplDriverEventSink = @Sendable (_ name: String, _ payloadJSON: String) -> Void

/// An engine driver behind the REPL runtime. See
/// `docs/browser-repl/driver-protocol.md` for methods and events.
public protocol BrowserReplDriver: AnyObject, Sendable {
    /// Capability names beyond the core protocol (`cdp`, `route`, ...).
    var capabilities: [String] { get }

    /// Runs one protocol method.
    /// - Parameters:
    ///   - method: Protocol method name, for example `tab.navigate`.
    ///   - paramsJSON: JSON object with the method's params.
    /// - Returns: JSON result (`null` when the method has none).
    func call(method: String, paramsJSON: String) async -> Result<String, BrowserReplDriverError>

    /// Starts delivering events to `sink` until `detach()`.
    func attach(eventSink: @escaping BrowserReplDriverEventSink)

    /// Stops events and releases held dialogs, file choosers and input state.
    func detach()
}

/// JSON helpers for values crossing the JavaScriptCore bridge.
public enum BrowserReplJSON {
    /// Encodes a JSON-compatible value (fragments allowed).
    public static func encode(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return "null" }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Decodes JSON text (fragments allowed). Returns `nil` for invalid JSON.
    public static func decode(_ text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// Decodes a JSON object, returning an empty dictionary for anything else.
    public static func object(_ text: String) -> [String: Any] {
        decode(text) as? [String: Any] ?? [:]
    }
}
