import CmuxMobileTerminalKit
import Foundation
import Testing
@testable import CmuxMobileShellUI

@Suite struct CustomToolbarMenuDraftItemTests {
    @Test func preservesNonTextPayloadWhenCommandIsUnchanged() {
        let nested = ToolbarMenuItem(
            title: "Back Tab",
            symbolName: "arrow.left.to.line",
            payload: .keyCombo(modifiers: [.shift], key: .tab)
        )
        let item = ToolbarMenuItem(
            title: "Navigation",
            symbolName: "folder",
            payload: .menu([nested])
        )

        var draft = CustomToolbarMenuDraftItem(menuItem: item)
        draft.title = "Nav"

        let saved = draft.toolbarMenuItem
        #expect(draft.isValid)
        #expect(saved.id == item.id)
        #expect(saved.title == "Nav")
        #expect(saved.symbolName == "folder")
        #expect(saved.payload == item.payload)
    }

    @Test func preservesTextRowSymbolWhenEditingCommand() {
        let item = ToolbarMenuItem(
            title: "List",
            symbolName: "list.bullet",
            payload: .text("ls\n")
        )

        var draft = CustomToolbarMenuDraftItem(menuItem: item)
        draft.commandText = "pwd"

        let saved = draft.toolbarMenuItem
        #expect(saved.symbolName == "list.bullet")
        #expect(saved.payload == .text("pwd\n"))
    }

    @Test func enteredCommandReplacesPreservedPayload() {
        let item = ToolbarMenuItem(
            title: "Back Tab",
            symbolName: "arrow.left.to.line",
            payload: .keyCombo(modifiers: [.shift], key: .tab)
        )

        var draft = CustomToolbarMenuDraftItem(menuItem: item)
        draft.commandText = "fg"

        let saved = draft.toolbarMenuItem
        #expect(saved.symbolName == "arrow.left.to.line")
        #expect(saved.payload == .text("fg"))
    }
}
