/// Why an app is installed (app-hide.md, critique C7).
public nonisolated enum AppInstallSource: String, Sendable, Hashable, Codable, CaseIterable {
    /// Installed on first launch (first-party apps, never samples).
    case `default`
    /// The user installed it.
    case user
    /// A team admin installed it for the team (record in `TeamDO`).
    case team
}

/// Which channels may still run an app while it is hidden. Defaults: all.
public nonisolated struct AppHiddenAccess: Sendable, Hashable, Codable {
    public var cli: Bool
    public var mcp: Bool
    public var automations: Bool

    public static let all = AppHiddenAccess(cli: true, mcp: true, automations: true)
    public static let noChannels = AppHiddenAccess(cli: false, mcp: false, automations: false)

    public init(cli: Bool, mcp: Bool, automations: Bool) {
        self.cli = cli
        self.mcp = mcp
        self.automations = automations
    }
}

/// One user's state for one app: personal and synced, owner `UserDO`
/// (a team install's record is `TeamDO`; this overlay stays `UserDO`).
/// Written only by `AppStateReducer`. A removed app keeps its record
/// (`source == nil`) so revisions stay monotone for every mirror.
public nonisolated struct AppInstallState: Sendable, Hashable, Codable, Identifiable {
    public var appID: String
    /// nil when not installed.
    public var source: AppInstallSource?
    /// false: nothing of the app runs or shows, hidden or not.
    public var enabled: Bool
    /// true: no presence on any user surface; still runs through the
    /// channels `hiddenAccess` allows.
    public var hidden: Bool
    public var hiddenAccess: AppHiddenAccess
    /// Increments on every change of this record.
    public var revision: UInt64

    public var id: String { appID }
    public var installed: Bool { source != nil }

    public init(appID: String, source: AppInstallSource? = nil, enabled: Bool = false, hidden: Bool = false,
                hiddenAccess: AppHiddenAccess = .all, revision: UInt64 = 0) {
        self.appID = appID
        self.source = source
        self.enabled = enabled
        self.hidden = hidden
        self.hiddenAccess = hiddenAccess
        self.revision = revision
    }

    /// A record for an app this user never installed.
    public static func notInstalled(_ appID: String) -> AppInstallState { AppInstallState(appID: appID) }
}
