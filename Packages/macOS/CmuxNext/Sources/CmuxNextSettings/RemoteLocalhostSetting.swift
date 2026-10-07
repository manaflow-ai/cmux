/// `browser.remoteLocalhost` and `browser.remoteLocalhostWorkspaces` in
/// cmux.json (plans/cmux-next/remote-localhost.md section 6).
///
/// `remoteLocalhost` (default `true`): a browser tab of a workspace that
/// lives on another machine opens that machine's localhost. `false` turns it
/// off everywhere, so localhost is this Mac again (the tab badge says so).
/// `remoteLocalhostWorkspaces` overrides it per workspace: an object from
/// workspace id (as `cmux list-workspaces` prints it for that machine) to
/// `true` or `false`.
public nonisolated struct RemoteLocalhostSetting: Sendable, Hashable {
    public var enabled: Bool
    public var workspaceOverrides: [String: Bool]

    public static let fallback = RemoteLocalhostSetting(enabled: true, workspaceOverrides: [:])

    public init(enabled: Bool, workspaceOverrides: [String: Bool]) {
        self.enabled = enabled
        self.workspaceOverrides = workspaceOverrides
    }

    /// Whether workspace `id` uses its machine's localhost.
    public func isEnabled(workspace id: String?) -> Bool {
        id.flatMap { workspaceOverrides[$0] } ?? enabled
    }

    static func parse(_ root: JSONValue) -> (RemoteLocalhostSetting, [SettingsDiagnostic]) {
        guard case .object(let browser)? = root["browser"] else { return (fallback, []) }
        var setting = fallback
        var diagnostics: [SettingsDiagnostic] = []
        if let value = browser["remoteLocalhost"] {
            if case .bool(let enabled) = value {
                setting.enabled = enabled
            } else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "browser.remoteLocalhost", message: "expected true or false"))
            }
        }
        if let value = browser["remoteLocalhostWorkspaces"] {
            guard case .object(let entries) = value else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "browser.remoteLocalhostWorkspaces",
                                                      message: "expected an object of workspace id to true or false"))
                return (setting, diagnostics)
            }
            for (id, entry) in entries {
                if case .bool(let enabled) = entry {
                    setting.workspaceOverrides[id] = enabled
                } else {
                    diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "browser.remoteLocalhostWorkspaces.\(id)",
                                                          message: "expected true or false"))
                }
            }
        }
        return (setting, diagnostics)
    }
}
