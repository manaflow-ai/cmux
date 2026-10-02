public import CmuxNextActions
public import CmuxNextSettings
import Foundation

/// The arguments of Settings… (`openSettings`): an optional page, and an
/// optional setting to scroll to and highlight, from the palette, the menu,
/// or `cmux action run openSettings --arg setting=tabs.newTabKind`.
public struct SettingsDeepLink: Equatable, Sendable {
    public var section: SettingsSection?
    /// A cmux.json key path, or another name `SettingsSearchIndex.anchor(for:)`
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

    /// Where the window scrolls: nil without a setting, or when nothing in
    /// Settings has that name (the caller reports it).
    public var anchor: SettingsAnchor? { setting.flatMap { SettingsSearchIndex.anchor(for: $0) } }

    private static func text(_ value: ActionValue?) -> String? {
        guard let text = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}
