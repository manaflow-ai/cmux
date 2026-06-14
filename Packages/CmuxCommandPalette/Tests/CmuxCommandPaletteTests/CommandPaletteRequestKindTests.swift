import Foundation
import Testing

@testable import CmuxCommandPalette

@Suite struct CommandPaletteRequestKindTests {
    @Test func notificationNamesMatchLegacyLiterals() {
        #expect(CommandPaletteRequestKind.commands.notificationName == "cmux.commandPaletteRequested")
        #expect(CommandPaletteRequestKind.switcher.notificationName == "cmux.commandPaletteSwitcherRequested")
        #expect(CommandPaletteRequestKind.renameTab.notificationName == "cmux.commandPaletteRenameTabRequested")
        #expect(CommandPaletteRequestKind.renameWorkspace.notificationName == "cmux.commandPaletteRenameWorkspaceRequested")
        #expect(
            CommandPaletteRequestKind.editWorkspaceDescription.notificationName
                == "cmux.commandPaletteEditWorkspaceDescriptionRequested"
        )
    }

    @Test func everyKindMarksPending() {
        for kind in CommandPaletteRequestKind.allCases {
            #expect(kind.marksPending)
        }
    }

    @Test func notificationNamesAreDistinct() {
        let names = Set(CommandPaletteRequestKind.allCases.map(\.notificationName))
        #expect(names.count == CommandPaletteRequestKind.allCases.count)
    }
}
