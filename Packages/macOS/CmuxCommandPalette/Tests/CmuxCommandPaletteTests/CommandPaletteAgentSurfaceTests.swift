import Foundation
import Testing

@testable import CmuxCommandPalette

@Suite struct CommandPaletteAgentSurfaceTests {
    private func candidate(
        _ commandId: String,
        isVisible: Bool = true,
        isEnabled: Bool = true,
        isHiddenFromPalette: Bool = false,
        title: String = "Title",
        subtitle: String = "Subtitle",
        shortcutHint: String? = nil
    ) -> CommandPaletteAgentCommandCandidate {
        CommandPaletteAgentCommandCandidate(
            commandId: commandId,
            title: title,
            subtitle: subtitle,
            shortcutHint: shortcutHint,
            isVisible: isVisible,
            isEnabled: isEnabled,
            isHiddenFromPalette: isHiddenFromPalette
        )
    }

    /// The distinction the listing exists for. The palette drops both of these
    /// rows, because a person cannot press either one; an agent has to tell
    /// "no such command here" from "not until something changes".
    @Test func whenHidesACommandAndEnablementOnlyDisablesIt() {
        let commands = CommandPaletteAgentSurface.commands(from: [
            candidate("palette.a", isVisible: false),
            candidate("palette.b", isEnabled: false),
            candidate("palette.c"),
        ])
        #expect(commands.map(\.commandId) == ["palette.b", "palette.c"])
        #expect(commands.first?.isEnabled == false)
        #expect(commands.last?.isEnabled == true)
    }

    /// A command the user's config takes out of the palette is not listed: the
    /// reply is the palette, not a catalogue of everything the app can do.
    @Test func configHidingACommandKeepsItOutOfTheListing() {
        let commands = CommandPaletteAgentSurface.commands(from: [
            candidate("palette.hidden", isHiddenFromPalette: true),
            candidate("palette.shown"),
        ])
        #expect(commands.map(\.commandId) == ["palette.shown"])
    }

    /// The exclusions hold whatever the predicates say, so a permissive context
    /// cannot leak them.
    @Test func excludedIdsAreNeverListed() {
        let excluded = CommandPaletteAgentSurface.notAgentSurfaceCommandIds.sorted()
        #expect(!excluded.isEmpty)
        let commands = CommandPaletteAgentSurface.commands(
            from: excluded.map { candidate($0) } + [candidate("palette.ok")]
        )
        #expect(commands.map(\.commandId) == ["palette.ok"])
    }

    /// Order is the palette's order, and display strings are passed through
    /// untouched: the listing renames nothing.
    @Test func listingKeepsPaletteOrderAndDisplayStrings() {
        let commands = CommandPaletteAgentSurface.commands(from: [
            candidate("palette.second", title: "Second", subtitle: "View", shortcutHint: "⌘2"),
            candidate("palette.first", title: "First", subtitle: "Workspace"),
        ])
        #expect(commands.map(\.commandId) == ["palette.second", "palette.first"])
        #expect(commands.first?.title == "Second")
        #expect(commands.first?.subtitle == "View")
        #expect(commands.first?.shortcutHint == "⌘2")
        #expect(commands.last?.shortcutHint == nil)
    }

    /// Two rows an agent cannot tell apart are worse than one, so the first
    /// wins, as it does on screen.
    @Test func duplicateIdsCollapseToTheFirstRow() {
        let commands = CommandPaletteAgentSurface.commands(from: [
            candidate("palette.dup", title: "Kept"),
            candidate("palette.dup", title: "Dropped"),
        ])
        #expect(commands.map(\.commandId) == ["palette.dup"])
        #expect(commands.first?.title == "Kept")
    }
}
