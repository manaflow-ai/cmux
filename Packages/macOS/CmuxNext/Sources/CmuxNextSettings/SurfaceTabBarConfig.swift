public import Foundation

/// One button of the trailing group in every pane's tab strip
/// (`ui.surfaceTabBar.buttons`). Every button runs a registry action.
public struct TabBarButtonSpec: Sendable, Hashable, Identifiable {
    /// Unique within the list.
    public var id: String
    /// Registry action run on click, targeted at the button's pane. Built-in
    /// config IDs (`cmux.splitRight`) are already mapped to catalog IDs
    /// (`splitRight`); config actions use `cmuxConfig.<name>`.
    public var actionID: String
    /// Overrides from the button entry or its config action. Nil falls back
    /// to the registry title and descriptor symbol.
    public var title: String?
    public var tooltip: String?
    public var icon: ConfigIcon?

    public init(id: String, actionID: String, title: String? = nil, tooltip: String? = nil, icon: ConfigIcon? = nil) {
        self.id = id
        self.actionID = actionID
        self.title = title
        self.tooltip = tooltip
        self.icon = icon
    }
}

/// The resolved `ui.surfaceTabBar` section plus the command actions it (and
/// the palette) can run.
public struct SurfaceTabBarConfig: Sendable, Hashable {
    /// Buttons in display order.
    public var buttons: [TabBarButtonSpec]
    /// True when cmux.json does not set the list, so `buttons` are the defaults.
    public var usesDefaults: Bool

    public init(buttons: [TabBarButtonSpec], usesDefaults: Bool) {
        self.buttons = buttons
        self.usesDefaults = usesDefaults
    }

    /// No configured buttons by default: the app shows its default cluster
    /// (split and more, by the selected tab's kind; CmuxNextApp `PaneToolbar`)
    /// on hover. A list in cmux-next.json (`ui.surfaceTabBar.buttons`)
    /// replaces it; an empty list shows none.
    public static let defaultButtons: [TabBarButtonSpec] = []

    /// The built-in buttons a user can add back: new terminal tab, split
    /// right, split down.
    public static let builtInButtons: [TabBarButtonSpec] = [
        TabBarButtonSpec(id: "cmux.newTerminal", actionID: "newSurface", icon: .symbol("terminal")),
        TabBarButtonSpec(id: "cmux.splitRight", actionID: "splitRight", icon: .symbol("square.split.2x1")),
        TabBarButtonSpec(id: "cmux.splitDown", actionID: "splitDown", icon: .symbol("square.split.1x2")),
    ]

    public static let defaults = SurfaceTabBarConfig(buttons: defaultButtons, usesDefaults: true)
}
