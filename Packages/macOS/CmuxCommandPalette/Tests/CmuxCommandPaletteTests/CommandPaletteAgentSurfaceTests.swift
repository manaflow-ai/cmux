import Foundation
import Testing

@testable import CmuxCommandPalette

@Suite struct CommandPaletteAgentSurfaceTests {
    private let surface = CommandPaletteAgentSurface.app

    private func candidate(
        _ commandId: String,
        isVisible: Bool = true,
        isEnabled: Bool = true,
        isHiddenFromPalette: Bool = false,
        hasRegisteredHandler: Bool = true,
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
            isHiddenFromPalette: isHiddenFromPalette,
            hasRegisteredHandler: hasRegisteredHandler
        )
    }

    /// The distinction the listing exists for. The palette drops both of these
    /// rows, because a person cannot press either one; an agent has to tell
    /// "no such command here" from "not until something changes".
    @Test func whenHidesACommandAndEnablementOnlyDisablesIt() {
        let commands = surface.commands(from: [
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
        let commands = surface.commands(from: [
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
        let commands = surface.commands(
            from: excluded.map { candidate($0) } + [candidate("palette.ok")]
        )
        #expect(commands.map(\.commandId) == ["palette.ok"])
    }

    /// Order is the palette's order, and display strings are passed through
    /// untouched: the listing renames nothing.
    @Test func listingKeepsPaletteOrderAndDisplayStrings() {
        let commands = surface.commands(from: [
            candidate("palette.second", title: "Second", subtitle: "View", shortcutHint: "⌘2"),
            candidate("palette.first", title: "First", subtitle: "Workspace"),
        ])
        #expect(commands.map(\.commandId) == ["palette.second", "palette.first"])
        #expect(commands.first?.title == "Second")
        #expect(commands.first?.subtitle == "View")
        #expect(commands.first?.shortcutHint == "⌘2")
        #expect(commands.last?.shortcutHint == nil)
    }

    /// The palette refuses to draw a contribution with no registered handler,
    /// so a listing that showed one would name a command that does nothing.
    @Test func aCommandWithNoHandlerIsNotListed() {
        let commands = surface.commands(from: [
            candidate("palette.unhandled", hasRegisteredHandler: false),
            candidate("palette.handled"),
        ])
        #expect(commands.map(\.commandId) == ["palette.handled"])
    }

    /// The exclusion set is injected, so what a surface hides is a property of
    /// that surface rather than a global the tests have to work around.
    @Test func aSurfaceHidesOnlyItsOwnExclusions() {
        let narrow = CommandPaletteAgentSurface(excludedCommandIds: ["palette.secret"])
        let commands = narrow.commands(from: [
            candidate("palette.secret"),
            candidate("palette.installCLI"),
        ])
        #expect(commands.map(\.commandId) == ["palette.installCLI"])
    }

    /// Two rows an agent cannot tell apart are worse than one, so the first
    /// wins, as it does on screen.
    @Test func duplicateIdsCollapseToTheFirstRow() {
        let commands = surface.commands(from: [
            candidate("palette.dup", title: "Kept"),
            candidate("palette.dup", title: "Dropped"),
        ])
        #expect(commands.map(\.commandId) == ["palette.dup"])
        #expect(commands.first?.title == "Kept")
    }
}
