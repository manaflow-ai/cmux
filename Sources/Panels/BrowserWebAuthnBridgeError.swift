struct BrowserWebAuthnBridgeError: Error {
    private let name: String
    private let message: String

    func replyObject() -> [String: Any] {
        [
            "ok": false,
            "error": [
                "name": name,
                "message": message,
            ],
        ]
    }

    static func invalidState(_ message: String) -> Self {
        .init(name: "InvalidStateError", message: message)
    }

    static func notAllowed(_ message: String) -> Self {
        .init(name: "NotAllowedError", message: message)
    }

    static func notSupported(_ message: String) -> Self {
        .init(name: "NotSupportedError", message: message)
    }

    static func security(_ message: String) -> Self {
        .init(name: "SecurityError", message: message)
    }

    static func type(_ message: String) -> Self {
        .init(name: "TypeError", message: message)
    }

    static func unknown(_ message: String) -> Self {
        .init(name: "UnknownError", message: message)
    }
}
