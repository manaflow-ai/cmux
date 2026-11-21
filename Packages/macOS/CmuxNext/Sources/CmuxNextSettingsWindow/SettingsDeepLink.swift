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
    /// A page-only place (`#/settings/personalization?focus=card.customizeDoctor`, the customize
    /// doctor's toast) that no section or setting names; only a `#/settings/` route is read.
    /// In-process callers only: the action catalog declares no `route` argument.
    public var route: String?

    public init(section: SettingsSection? = nil, setting: String? = nil, route: String? = nil) {
        self.section = section
        self.setting = setting
        self.route = route
    }

    /// Reads `section` (an unknown name is ignored, as before), `setting` (trimmed; blank is
    /// none) and `route` (a `#/settings/` route, else none).
    public init(_ invocation: ActionInvocation) {
        section = Self.text(invocation["section"]).flatMap(SettingsSection.init(rawValue:))
        setting = Self.text(invocation["setting"])
        route = Self.text(invocation["route"]).flatMap { $0.hasPrefix("#/settings/") ? $0 : nil }
    }

    /// Settings > Appearance's page route, on its background picker when `background` (Change
    /// Background…) and for `workspace` (the picker's This Workspace) when given. Personalization
    /// folded into Appearance (one settings area, David Beyer 2026-11-20), so Personalization… opens
    /// the bare route. A background route is new at each request (`open`, which the page reads only
    /// to show the picker again): the host opens a route only when it differs from the last one it
    /// opened, and the person may have scrolled away since, so a repeat Change Background… lands again.
    public static func appearanceRoute(background: Bool = false, workspace: String? = nil,
                                       open: UInt64? = nil) -> String {
        var query: [String] = []
        if background {
            query.append(contentsOf: ["focus=appearance.background", "open=\(open ?? DispatchTime.now().uptimeNanoseconds)"])
        }
        if let workspace, let id = workspace.addingPercentEncoding(withAllowedCharacters: .alphanumerics) { query.append("workspace=\(id)") }
        return "#/settings/appearance" + (query.isEmpty ? "" : "?" + query.joined(separator: "&"))
    }

    /// Where the window scrolls: nil without a setting, or when nothing in
    /// Settings has that name (the caller reports it).
    public var anchor: SettingsAnchor? { setting.flatMap { SettingsAnchor(key: $0) } }

    private static func text(_ value: ActionValue?) -> String? {
        guard let text = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}
