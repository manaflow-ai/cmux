public struct BrowserWebAuthnBridgeError: Error {
    private let name: String
    private let message: String

    public func replyObject() -> [String: Any] {
        [
            "ok": false,
            "error": [
                "name": name,
                "message": message,
            ],
        ]
    }

    public static func invalidState(_ message: String) -> Self {
        .init(name: "InvalidStateError", message: message)
    }

    public static func notAllowed(_ message: String) -> Self {
        .init(name: "NotAllowedError", message: message)
    }

    public static func notSupported(_ message: String) -> Self {
        .init(name: "NotSupportedError", message: message)
    }

    public static func security(_ message: String) -> Self {
        .init(name: "SecurityError", message: message)
    }

    public static func type(_ message: String) -> Self {
        .init(name: "TypeError", message: message)
    }

    public static func unknown(_ message: String) -> Self {
        .init(name: "UnknownError", message: message)
    }
}
