#if os(iOS)
import CmuxMobileTerminalKit
import Foundation

struct CustomToolbarMenuDraftItem: Identifiable {
    let id: UUID
    var title: String
    var commandText: String
    var runAfterTyping: Bool

    init(
        id: UUID = UUID(),
        title: String = "",
        commandText: String = "",
        runAfterTyping: Bool = true
    ) {
        self.id = id
        self.title = title
        self.commandText = commandText
        self.runAfterTyping = runAfterTyping
    }

    init(menuItem: ToolbarMenuItem) {
        guard case let .text(stored) = menuItem.payload else {
            self.init(
                id: menuItem.id,
                title: menuItem.title,
                commandText: "",
                runAfterTyping: false
            )
            return
        }
        if stored.hasSuffix("\n") {
            self.init(
                id: menuItem.id,
                title: menuItem.title,
                commandText: String(stored.dropLast()),
                runAfterTyping: true
            )
        } else {
            self.init(
                id: menuItem.id,
                title: menuItem.title,
                commandText: stored,
                runAfterTyping: false
            )
        }
    }

    var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isValid: Bool {
        !trimmedTitle.isEmpty && !commandText.isEmpty
    }

    var toolbarMenuItem: ToolbarMenuItem {
        let text = runAfterTyping ? commandText + "\n" : commandText
        return ToolbarMenuItem(
            id: id,
            title: trimmedTitle,
            symbolName: nil,
            payload: .text(text)
        )
    }
}
#endif
