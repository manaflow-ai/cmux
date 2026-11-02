@testable import CmuxNextActions
import Testing

/// The user, 2026-10-30: "on hover on new message should be x button". The draft row's x,
/// Escape in an empty To: field, the palette (Cmd-Shift-P), `cmux home close-new-message` and
/// MCP all run one catalog action, Close New Message.
@MainActor
struct HomeCloseNewMessageActionTests {
    @Test func closeNewMessageIsOfferedInThePaletteTheCLIAndMCP() throws {
        let registry = ActionRegistry.standard()
        let descriptor = try #require(registry.descriptor(for: "home.closeNewMessage"))
        #expect(descriptor.title == "Close New Message")
        #expect(descriptor.cliName == "home close-new-message")
        #expect(descriptor.surfaces.contains(.palette))
        for surface: ActionSurface in [.palette, .cli, .mcp] {
            #expect(descriptor.surfacePlan.decision(for: surface)?.isOffered == true, "\(surface) does not offer it")
        }
    }

    @Test func theRegistryRunsTheBoundCloseOnce() throws {
        let registry = ActionRegistry.standard()
        var closes = 0
        registry.bind("home.closeNewMessage", invoke: { _ in closes += 1 })
        _ = registry.perform("home.closeNewMessage", invocation: ActionInvocation(origin: .user))
        #expect(closes == 1)
    }
}
