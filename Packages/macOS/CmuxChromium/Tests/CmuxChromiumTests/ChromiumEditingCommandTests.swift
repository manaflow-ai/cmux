import Testing
@testable import CmuxChromium

struct ChromiumEditingCommandTests {
    private func command(
        _ characters: String?,
        command: Bool = true,
        shift: Bool = false,
        option: Bool = false,
        control: Bool = false
    ) -> ChromiumEditingCommand? {
        ChromiumEditingCommand(
            characters: characters,
            command: command,
            shift: shift,
            option: option,
            control: control
        )
    }

    @Test func mapsStandardEditingKeyEquivalents() {
        #expect(command("a") == .selectAll)
        #expect(command("c") == .copy)
        #expect(command("x") == .cut)
        #expect(command("v") == .paste)
        #expect(command("z") == .undo)
        #expect(command("z", shift: true) == .redo)
        #expect(command("v", shift: true) == .paste)
    }

    @Test func uppercaseCharactersMapLikeLowercase() {
        #expect(command("A") == .selectAll)
        #expect(command("Z", shift: true) == .redo)
    }

    @Test func requiresCommandModifier() {
        #expect(command("a", command: false) == nil)
        #expect(command("z", command: false, shift: true) == nil)
    }

    @Test func declinesOptionAndControlChords() {
        #expect(command("a", option: true) == nil)
        #expect(command("c", control: true) == nil)
        #expect(command("v", shift: true, option: true) == nil)
    }

    @Test func declinesShiftedSelectionAndClipboardChords() {
        // ⇧⌘A / ⇧⌘C / ⇧⌘X belong to cmux or the menu, not page editing.
        #expect(command("a", shift: true) == nil)
        #expect(command("c", shift: true) == nil)
        #expect(command("x", shift: true) == nil)
    }

    @Test func declinesUnrelatedKeys() {
        #expect(command("t") == nil)
        #expect(command("w") == nil)
        #expect(command("l") == nil)
        #expect(command(nil) == nil)
    }
}
