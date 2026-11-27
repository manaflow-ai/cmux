/// How the floating Chief looks (`home.chiefPanel.style`, user 2026-11-07: "see how minimal it can get, since it
/// will float everywhere"). Docked, the Chief always shows as a Chief-only pane with its bar.
///
/// The collapsing styles rest small while the keys are elsewhere and grow into the whole chat once the Chief has the
/// keys (a click in its message box, Show/Hide Chief):
///
/// ```swift
/// let style = ChiefPanelStyle(rawValue: "pill") ?? .default
/// ```
public enum ChiefPanelStyle: String, CaseIterable, Sendable {
    /// Only the Chief's message box, a grip at its left; it grows into the chat. The default: the least on screen
    /// that still takes a message.
    case composeBar
    /// The message box in a slim, round pill; it grows into the chat.
    case pill
    /// The whole chat with no title bar: a thin grip strip with small Dock and Hide buttons.
    case card
    /// The whole chat under a title bar with the Chief's name, Dock and Hide.
    case panel
    /// A round button with the Chief's mark; a click grows it into the chat.
    case bubble
    /// The chat's bubbles over the workspace, as in Messages: no panel glass, a glass plate under the message box.
    case seeThrough
    /// The see-through message box alone; it grows into the see-through chat.
    case seeThroughBar

    /// Whether the style rests small and grows into the chat with the keys.
    public var collapses: Bool { self == .composeBar || self == .pill || self == .bubble || self == .seeThroughBar }

    /// Whether the panel draws no glass behind the chat (the workspace shows between the bubbles).
    public var isSeeThrough: Bool { self == .seeThrough || self == .seeThroughBar }

    /// The style a window uses when the setting is unset or unknown.
    public static let `default` = ChiefPanelStyle.composeBar
}
