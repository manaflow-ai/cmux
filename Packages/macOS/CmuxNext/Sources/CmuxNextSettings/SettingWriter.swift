public import CmuxNextActions
public import Foundation

/// Who writes a setting (SECURITY, agent_settable enforcement). The one rule, at the one write
/// path (`SettingsController.setSetting` / `resetAllSettings`): the user may write any unmanaged
/// key; every other caller (cli, mcp, script, remote, a page) may write only
/// `SettingsSchema.agentSettableKeys`, else `SettingUserOnly`. Managed keys are refused for all.
/// There is no default: every caller says who it acts for.
public nonisolated enum SettingWriter: Sendable, Hashable {
    /// A person: a gesture in the app's own UI, or a call a native confirmation approved.
    case user
    /// Anyone else, by origin name (`cli`, `mcp`, `script`, `remote`, `page`).
    case caller(String)

    /// The writer of an action run's origin.
    public init(_ origin: ActionOrigin) {
        self = origin == .user ? .user : .caller(origin.rawValue)
    }

    /// The writer of the action run in progress (`ActionRunScope.current`); outside a run the
    /// write comes from a direct gesture in the app's own UI (a click, a drag), so `user`.
    public static func currentRun() -> SettingWriter {
        ActionRunScope.current.map { SettingWriter($0.origin) } ?? .user
    }

    /// Whether this writer may change `descriptor`.
    public func mayWrite(_ descriptor: SettingDescriptor) -> Bool {
        self == .user || SettingsSchema.agentSettableKeys.contains(descriptor.id)
    }
}

/// A write by a non-user caller to a key only the user may change.
public nonisolated struct SettingUserOnly: Error, Sendable, CustomStringConvertible, Equatable {
    public let key: String
    public let writer: SettingWriter

    public init(key: String, writer: SettingWriter) {
        self.key = key
        self.writer = writer
    }

    public var description: String {
        "\(key) can be changed only by you, in Settings (agents, scripts and pages cannot change it)"
    }
}
