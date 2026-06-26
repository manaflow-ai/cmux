/// A WebAuthn bridge failure carrying the DOM error name and message that the
/// page world rethrows as a `DOMException`/`TypeError`.
public struct BrowserWebAuthnBridgeError: Error {
    /// The DOM error name reported to JavaScript.
    public let name: BrowserWebAuthnErrorName
    /// The human-readable error message reported to JavaScript.
    public let message: String

    /// The reply dictionary posted back to the page world for a failed request.
    public func replyObject() -> [String: Any] {
        [
            "ok": false,
            "error": [
                "name": name.rawValue,
                "message": message,
            ],
        ]
    }

    public static func invalidState(_ message: String) -> Self {
        .init(name: .invalidState, message: message)
    }

    public static func notAllowed(_ message: String) -> Self {
        .init(name: .notAllowed, message: message)
    }

    public static func notSupported(_ message: String) -> Self {
        .init(name: .notSupported, message: message)
    }

    public static func security(_ message: String) -> Self {
        .init(name: .security, message: message)
    }

    public static func type(_ message: String) -> Self {
        .init(name: .type, message: message)
    }

    public static func unknown(_ message: String) -> Self {
        .init(name: .unknown, message: message)
    }
}
