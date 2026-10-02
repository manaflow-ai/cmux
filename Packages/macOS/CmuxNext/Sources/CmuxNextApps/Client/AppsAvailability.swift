/// Why the app supervisor cannot be reached.
public nonisolated enum AppsUnavailableReason: Sendable, Hashable {
    /// The daemon runs but lacks the `apps-v1` capability.
    case needsNewerDaemon
    /// The daemon is not connected (starting, restarting, gone).
    case notConnected
}

/// Whether the supervisor answers. `epoch` changes on every (re)connect:
/// the client then lists again, re-mounts and resends its pending intents.
public nonisolated enum AppsAvailability: Sendable, Hashable {
    case available(epoch: Int)
    case unavailable(AppsUnavailableReason)

    public var isAvailable: Bool { if case .available = self { true } else { false } }
}

/// A supervisor refusal or a failed call (`error_code` and `error` of the
/// daemon reply, or a transport failure without a code).
public nonisolated struct AppsTransportError: Error, Sendable, Hashable, CustomStringConvertible {
    public var code: String?
    public var message: String

    public init(code: String? = nil, message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { code.map { "\(message) [\($0)]" } ?? message }
}
