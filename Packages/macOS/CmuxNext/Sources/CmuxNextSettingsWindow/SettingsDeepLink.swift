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

    /// Reopening customization returns to Sidebar even if the retained Settings tab navigated away.
    public static func sidebarRoute(open: UInt64? = nil) -> String {
        "#/settings/sidebar?open=\(open ?? DispatchTime.now().uptimeNanoseconds)"
    }

    /// The page fragment for `section` and `setting`: a schema setting focuses its row; any other
    /// anchor opens its section.
    /// The Development section (and its keys) exists only in DEV and NIGHTLY builds: elsewhere a request for
    /// it opens Settings on the default page (the page hides the category the same way).
    public static func route(section: SettingsSection?, setting: String?, devBuild: Bool = DevTools.isEnabled) -> String? {
        if let setting, let descriptor = SettingsSchema.descriptor(for: CmuxConfigFile.keyPath(from: setting)) {
            guard descriptor.section != .development || devBuild else { return nil }
            return "#/settings/\(descriptor.section.rawValue)?focus=\(descriptor.id)"
        }
        guard let section, section != .development || devBuild else { return nil }
        return "#/settings/\(section.rawValue)"
    }

    /// Settings > Customize (App menu > Customizations' last row); a page without that category opens
    /// its default one (`categoryOf` in webviews/src/pages/settings/categories.ts).
    public static let customizeRoute = "#/settings/customize"

    /// Where the window scrolls: nil without a setting, or when nothing in
    /// Settings has that name (the caller reports it).
    public var anchor: SettingsAnchor? { setting.flatMap { SettingsAnchor(key: $0) } }

    private static func text(_ value: ActionValue?) -> String? {
        guard let text = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}
