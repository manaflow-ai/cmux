public import CmuxNextActions
public import CmuxNextSettings
import Foundation

/// The arguments of Settings… (`openSettings`): an optional page, and an
/// optional setting to scroll to and highlight, from the palette, the menu,
/// or `cmux action run openSettings --arg setting=tabs.newTabPosition`.
public struct SettingsDeepLink: Equatable, Sendable {
    public var section: SettingsSection?
    /// A cmux.json key path, or another name `SettingsAnchor(key:)`
    /// knows; nil when absent or blank.
    public var setting: String?

    public init(section: SettingsSection? = nil, setting: String? = nil) {
        self.section = section
        self.setting = setting
    }

    /// Reads `section` (an unknown name is ignored, as before) and
    /// `setting` (trimmed; blank is none).
    public init(_ invocation: ActionInvocation) {
        section = Self.text(invocation["section"]).flatMap(SettingsSection.init(rawValue:))
        setting = Self.text(invocation["setting"])
    }

    /// Settings > Personalization's page route (Personalization…), on `part` (its jump bar's
    /// `background`, `theme`, ...) and for `workspace` (Change Background…'s This Workspace) when given.
    /// A route with a part is new at each request (`open`, which the page ignores, as Customize
    /// Menu…'s): the host opens a route only when it differs from the last one it opened, and the
    /// person may have jumped to another part since, so a repeat Change Background… lands again.
    public static func personalizationRoute(part: String? = nil, workspace: String? = nil,
                                            open: UInt64? = nil) -> String {
        var query: [String] = []
        if let part {
            query.append(contentsOf: ["focus=personalization.\(part)", "open=\(open ?? DispatchTime.now().uptimeNanoseconds)"])
        }
        if let workspace, let id = workspace.addingPercentEncoding(withAllowedCharacters: .alphanumerics) { query.append("workspace=\(id)") }
        return "#/settings/personalization" + (query.isEmpty ? "" : "?" + query.joined(separator: "&"))
    }

    /// Where the window scrolls: nil without a setting, or when nothing in
    /// Settings has that name (the caller reports it).
    public var anchor: SettingsAnchor? { setting.flatMap { SettingsAnchor(key: $0) } }

    private static func text(_ value: ActionValue?) -> String? {
        guard let text = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}
