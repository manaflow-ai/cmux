import Foundation

/// Row titles in an agent chat's empty-space menu (``ContextMenuPlacement/label``): the menu is the
/// chat's own, so its rows drop the palette's "Agent Chat:" prefix and name the chat.
nonisolated enum AgentChatMenuLabels {
    static var theme: String { text("menu.agentChat.theme", "Theme") }
    static var zoomIn: String { text("menu.agentChat.zoomIn", "Zoom In") }
    static var zoomOut: String { text("menu.agentChat.zoomOut", "Zoom Out") }
    static var actualSize: String { text("menu.agentChat.actualSize", "Actual Size") }
    static var findInChat: String { text("menu.agentChat.findInChat", "Find in Chat…") }

    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        ("\u{E000}AgentChatMenu\u{E001}" + String(describing: key) + "\u{E002}" + String(localized: key, defaultValue: value, table: "AgentChatMenu", bundle: .module))
    }
}
