import CmuxNextActions
import Testing

/// Quit and the local terminals (user decision 2026-09-30): `cmux app quit`
/// takes `--keep-sessions` / `--end-sessions`, and the same two choices are
/// palette actions and app menu items.
@MainActor
@Suite struct QuitActionsTests {
    let registry = ActionRegistry.standard()

    @Test func quitTakesOptionalKeepAndEndSessionFlags() throws {
        let quit = try #require(registry.descriptor(for: "quit"))
        #expect(quit.cliName == "app quit")
        for name in ["keepSessions", "endSessions"] {
            let argument = try #require(quit.arguments.first { $0.name == name })
            #expect(argument.kind == .bool)
            #expect(!argument.isRequired)
            #expect(argument.parse("true") == .bool(true))
        }
    }

    @Test func keepAndEndAreActionsOnEveryEntrypoint() throws {
        for (id, cli) in [("quitKeepSessions", "app quit-keep-sessions"), ("quitEndSessions", "app quit-end-sessions")] {
            let descriptor = try #require(registry.descriptor(for: ActionID(rawValue: id)))
            #expect(descriptor.cliName == cli)
            #expect(descriptor.mainMenu == .app)
            #expect(descriptor.isPaletteVisible)
            #expect(!descriptor.isDestructive, "a named quit choice runs as asked, like Quit itself")
        }
        #expect(registry.descriptor(for: "quitKeepSessions")?.title == "Quit and Keep Sessions")
        #expect(registry.descriptor(for: "quitEndSessions")?.title == "Quit and End Sessions")
    }
}
