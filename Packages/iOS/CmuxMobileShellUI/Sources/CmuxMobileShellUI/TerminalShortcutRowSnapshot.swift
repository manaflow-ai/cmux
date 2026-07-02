#if os(iOS)
import CmuxMobileTerminal
import CmuxMobileTerminalKit

struct TerminalShortcutRowSnapshot: Identifiable {
    let item: ResolvedToolbarItem
    let isEnabled: Bool

    var id: ToolbarItemID {
        item.id
    }

    var isCustom: Bool {
        item.isCustom
    }

    var customAction: CustomToolbarAction? {
        item.customAction
    }

    var settingsDisplayName: String {
        item.settingsDisplayName
    }

    var symbolName: String {
        guard let customAction else { return "character.cursor.ibeam" }
        if customAction.isMenu { return "ellipsis.circle" }
        return "character.cursor.ibeam"
    }
}
#endif
