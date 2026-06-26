#if os(iOS)
import CmuxMobileSupport
import CmuxMobileTerminal
import CmuxMobileTerminalKit

enum TerminalShortcutsSettingsScope: Equatable {
    case terminal
    case agentChat

    func includes(_ item: ResolvedToolbarItem) -> Bool {
        switch self {
        case .terminal:
            true
        case .agentChat:
            item.isSupportedInAgentChat
        }
    }

    var navigationTitle: String {
        switch self {
        case .terminal:
            L10n.string("mobile.shortcuts.title", defaultValue: "Terminal Shortcuts")
        case .agentChat:
            L10n.string("mobile.shortcuts.chat.title", defaultValue: "Chat Shortcuts")
        }
    }

    var footer: String {
        switch self {
        case .terminal:
            L10n.string(
                "mobile.shortcuts.footer",
                defaultValue: "Choose which buttons appear on the terminal keyboard bar, and drag to reorder them. The modifier keys, zoom, and paste can be moved or hidden along with the shortcuts. Swipe a custom action to edit or delete it."
            )
        case .agentChat:
            L10n.string(
                "mobile.shortcuts.chat.footer",
                defaultValue: "Choose which compatible terminal buttons also appear on the chat keyboard bar, and drag to reorder them. Terminal-only controls stay available in terminal mode."
            )
        }
    }
}

extension ResolvedToolbarItem {
    var isSupportedInAgentChat: Bool {
        switch self {
        case let .builtin(action):
            action.isSupportedInAgentChat
        case let .custom(action):
            action.isSupportedInAgentChat
        }
    }
}

extension TerminalInputAccessoryAction {
    var isSupportedInAgentChat: Bool {
        switch self {
        case .control, .alternate, .command, .shift,
             .zoomOut, .zoomIn,
             .upArrow, .downArrow, .leftArrow, .rightArrow,
             .home, .end, .pageUp, .pageDown,
             .composer:
            false
        case .paste:
            true
        default:
            output != nil || self == .escape || self == .ctrlC
        }
    }
}

private extension CustomToolbarAction {
    var isSupportedInAgentChat: Bool {
        output != nil
    }
}
#endif
