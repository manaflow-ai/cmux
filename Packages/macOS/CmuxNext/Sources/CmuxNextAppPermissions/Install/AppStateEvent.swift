/// What a committed op emits. `changed` carries the whole record, so a
/// mirror converges by keeping the highest revision per app.
public nonisolated enum AppStateEvent: Sendable, Hashable, Codable {
    /// `app.changed {app, installed, enabled, hidden, revision}`.
    case changed(AppInstallState)
    /// Uninstall: the app's storage goes in the same commit.
    case storageRemoved(app: String)
    /// Uninstall: the app's grant goes in the same commit.
    case grantRemoved(app: String)
}

/// Why the owner refused an op.
public nonisolated enum AppStateReject: Error, Sendable, Hashable, Codable {
    /// The channel may not send this op (installs and hidden access are
    /// user only; no app state op is an MCP tool or an automation step).
    case originNotAllowed(AppStateOrigin)
    case notInstalled
    /// Only a team admin removes a team-installed app (members hide or disable it).
    case adminOnly
    /// The idempotency key was used before for a different op.
    case keyReused
    /// A default or team install from a principal that may not make one.
    case sourceNotAllowed(AppInstallSource)

    /// The error code CLI and UI show.
    public var code: String {
        switch self {
        case .originNotAllowed: "app.origin_not_allowed"
        case .notInstalled: "app.not_installed"
        case .adminOnly: "app.admin_only"
        case .keyReused: "idempotency.key_reused"
        case .sourceNotAllowed: "app.source_not_allowed"
        }
    }
}

/// The result of one accepted op.
public nonisolated struct AppStateCommit: Sendable, Hashable, Codable {
    public enum Outcome: String, Sendable, Hashable, Codable {
        /// The record changed.
        case applied
        /// Valid, but nothing to change (hide an already hidden app).
        case noChange
        /// A replay of an earlier key: no further effect.
        case replayed
        /// Remove of a default-installed app without confirmation: hidden instead.
        case convertedToHide
    }

    public var outcome: Outcome
    public var events: [AppStateEvent]

    public init(outcome: Outcome, events: [AppStateEvent]) {
        self.outcome = outcome
        self.events = events
    }
}
