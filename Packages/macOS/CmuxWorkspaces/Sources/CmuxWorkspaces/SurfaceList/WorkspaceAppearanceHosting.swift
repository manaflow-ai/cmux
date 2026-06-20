/// The live-workspace appearance state ``WorkspaceAppearanceModel`` reaches
/// back into.
///
/// ``WorkspaceAppearanceModel`` owns the per-workspace tab-color and
/// terminal-scrollbar transition logic the legacy `Workspace` god object kept
/// inline (`setCustomColor`, `setTerminalScrollBarHidden`). The state those
/// bodies read and write is the workspace's `@Published` appearance vocabulary
/// (`customColor`, `terminalScrollBarHidden`), whose `objectWillChange`
/// emissions drive the UI, and two app-coupled effects: the hex normalizer
/// `WorkspaceTabColorSettings.normalizedHex(_:)` (an app-target settings type)
/// and the `NotificationCenter` post on
/// `Workspace.terminalScrollBarHiddenDidChangeNotification` (an app-target
/// `Notification.Name`). The model reaches each property and effect through this
/// seam; the app target's `Workspace` conforms and is injected via
/// ``WorkspaceAppearanceModel/attach(host:)``.
///
/// Every member mirrors a read, write, or effect the legacy method bodies made
/// on `self` (`customColor`, `terminalScrollBarHidden`, the `normalizedHex`
/// call, the `terminalScrollBarHiddenDidChangeNotification` post), so the move
/// is byte-faithful.
@MainActor
public protocol WorkspaceAppearanceHosting: AnyObject {
    /// The workspace's custom tab color as a hex string, or `nil` when none is
    /// set (legacy `Workspace.customColor`). The setter is the `@Published`
    /// property ``WorkspaceAppearanceModel/setCustomColor(_:)`` assigns exactly
    /// as the legacy body did.
    var workspaceAppearanceCustomColor: String? { get set }

    /// Whether the per-workspace terminal scrollbar override is hidden (legacy
    /// `Workspace.terminalScrollBarHidden`). The setter is the `@Published`
    /// property ``WorkspaceAppearanceModel/setTerminalScrollBarHidden(_:)``
    /// assigns inside the changed branch exactly as the legacy body did.
    var workspaceAppearanceTerminalScrollBarHidden: Bool { get set }

    /// Normalizes a raw hex color string to the canonical `#RRGGBB` form, or
    /// `nil` when it is empty or malformed (legacy
    /// `WorkspaceTabColorSettings.normalizedHex(_:)`). Kept on the host so the
    /// app-target `WorkspaceTabColorSettings` settings type stays app-side.
    func workspaceAppearanceNormalizedColorHex(_ hex: String) -> String?

    /// Posts `Workspace.terminalScrollBarHiddenDidChangeNotification` on the
    /// default `NotificationCenter` with the workspace as `object` (legacy
    /// `setTerminalScrollBarHidden` post). Kept on the host so the app-target
    /// `Notification.Name` and the `object: self` reference stay app-side.
    func workspaceAppearancePostTerminalScrollBarHiddenDidChange()
}
