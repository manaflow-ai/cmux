import Foundation

/// The footer's update pill (SIDEBAR-FOOTER-MINIMAL). The App fills it from
/// the updater only while an update is staged ("Update Ready") or installing
/// (disabled); a click sends `SidebarIntent.installUpdate`.
public nonisolated struct SidebarUpdatePill: Hashable, Sendable {
    /// The pill's label.
    public var title: String
    /// Tooltip and VoiceOver label: what a click does and that sessions
    /// keep running.
    public var help: String
    /// False while the update installs (the click was taken).
    public var isEnabled: Bool

    public init(title: String, help: String, isEnabled: Bool = true) {
        self.title = title
        self.help = help
        self.isEnabled = isEnabled
    }
}
