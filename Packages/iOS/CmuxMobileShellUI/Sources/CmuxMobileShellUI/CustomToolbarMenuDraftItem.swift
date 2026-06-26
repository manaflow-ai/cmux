#if os(iOS)
import CmuxMobileTerminalKit
import Foundation

struct CustomToolbarMenuDraftItem: Identifiable {
    let id: UUID
    var title: String
    var symbolName: String?
    var commandText: String
    var runAfterTyping: Bool
    private var preservedPayload: ToolbarActionPayload?

    init(
        id: UUID = UUID(),
        title: String = "",
        symbolName: String? = nil,
        commandText: String = "",
        runAfterTyping: Bool = true,
        preservedPayload: ToolbarActionPayload? = nil
    ) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.commandText = commandText
        self.runAfterTyping = runAfterTyping
        self.preservedPayload = preservedPayload
    }

    init(menuItem: ToolbarMenuItem) {
        guard case let .text(stored) = menuItem.payload else {
            self.init(
                id: menuItem.id,
                title: menuItem.title,
                symbolName: menuItem.symbolName,
                commandText: "",
                runAfterTyping: false,
                preservedPayload: menuItem.payload
            )
            return
        }
        if stored.hasSuffix("\n") {
            self.init(
                id: menuItem.id,
                title: menuItem.title,
                symbolName: menuItem.symbolName,
                commandText: String(stored.dropLast()),
                runAfterTyping: true
            )
        } else {
            self.init(
                id: menuItem.id,
                title: menuItem.title,
                symbolName: menuItem.symbolName,
                commandText: stored,
                runAfterTyping: false
            )
        }
    }

    var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isValid: Bool {
        !trimmedTitle.isEmpty && (preservedPayload != nil || !commandText.isEmpty)
    }

    var toolbarMenuItem: ToolbarMenuItem {
        let payload: ToolbarActionPayload
        if commandText.isEmpty, let preservedPayload {
            payload = preservedPayload
        } else {
            let text = runAfterTyping ? commandText + "\n" : commandText
            payload = .text(text)
        }
        return ToolbarMenuItem(
            id: id,
            title: trimmedTitle,
            symbolName: symbolName,
            payload: payload
        )
    }
}
#endif
