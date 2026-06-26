#if os(iOS)
import CmuxMobileSupport
import CmuxMobileTerminalKit

extension TerminalSpecialKey {
    static var toolbarEditorOptions: [TerminalSpecialKey] {
        [
            .escape,
            .tab,
            .upArrow,
            .downArrow,
            .leftArrow,
            .rightArrow,
            .home,
            .end,
            .pageUp,
            .pageDown,
            .delete,
        ]
    }

    var toolbarEditorDisplayName: String {
        switch self {
        case .escape:
            L10n.string("terminal.shortcut.name.escape", defaultValue: "Escape")
        case .tab:
            L10n.string("terminal.shortcut.name.tab", defaultValue: "Tab")
        case .upArrow:
            L10n.string("terminal.shortcut.name.upArrow", defaultValue: "Up Arrow")
        case .downArrow:
            L10n.string("terminal.shortcut.name.downArrow", defaultValue: "Down Arrow")
        case .leftArrow:
            L10n.string("terminal.shortcut.name.leftArrow", defaultValue: "Left Arrow")
        case .rightArrow:
            L10n.string("terminal.shortcut.name.rightArrow", defaultValue: "Right Arrow")
        case .home:
            L10n.string("terminal.shortcut.name.home", defaultValue: "Home")
        case .end:
            L10n.string("terminal.shortcut.name.end", defaultValue: "End")
        case .pageUp:
            L10n.string("terminal.shortcut.name.pageUp", defaultValue: "Page Up")
        case .pageDown:
            L10n.string("terminal.shortcut.name.pageDown", defaultValue: "Page Down")
        case .delete:
            L10n.string("terminal.shortcut.name.delete", defaultValue: "Delete")
        }
    }
}
#endif
