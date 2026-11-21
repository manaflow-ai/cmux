/// Why the app supervisor cannot be reached.
public nonisolated enum AppsUnavailableReason: Sendable, Hashable {
    /// The daemon runs but serves no `apps-v1`: it has no `cmux-app-host` beside it (cmux-tui
    /// advertises the capability only when that binary exists). No update or restart adds it.
    case noAppHost
    /// The daemon is not connected (starting, restarting, gone).
    case notConnected
    /// The daemon is not connected, with its real cause from the daemon
    /// service (still restoring, the last connect error, the drop reason).
    case notReady(String)
    /// An administrator turned apps off on this Mac (DisabledFeatures); the
    /// text says so. Nothing mounts and nothing changes until it is back on.
    case turnedOff(String)

    /// The reason as shown (banner, app sections, action refusals).
    public var text: String { AppsStrings.unavailable(self) }

    /// cmux-tui itself is not connected (Retry Now and Restart cmux-tui can help).
    public var daemonUnreachable: Bool {
        switch self {
        case .notConnected, .notReady: true
        case .noAppHost, .turnedOff: false
        }
    }
}

/// Whether the supervisor answers. `epoch` changes on every (re)connect:
/// the client then lists again and re-mounts.
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
    /// The connection dropped before the reply (the request may or may not
    /// have reached the supervisor). A change then leaves the intent log
    /// without a rejection; the next connection's list shows the truth.
    public var connectionLost: Bool

    public init(code: String? = nil, message: String, connectionLost: Bool = false) {
        self.code = code
        self.message = message
        self.connectionLost = connectionLost
    }

    public var description: String { code.map { "\(message) [\($0)]" } ?? message }
}

nonisolated extension AppsUnavailableReason {
    /// The supervisor's daemon capability: cmux-tui advertises it only when the `cmux-app-host` binary exists.
    public static let daemonCapability = "apps-v1"

    /// Why the supervisor cannot be used: `capabilities` of the connected
    /// daemon, nil when none is connected (`cause`: the daemon service's reason).
    public static func daemon(capabilities: [String]?, cause: String? = nil) -> AppsUnavailableReason? {
        guard let capabilities else { return cause.map(AppsUnavailableReason.notReady) ?? .notConnected }
        return capabilities.contains(daemonCapability) ? nil : .noAppHost
    }
}
