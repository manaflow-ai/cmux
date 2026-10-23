import AppKit
import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
import Foundation
import Testing

/// Fork Conversation (Cmd-Shift-P's "Fork Conversation…" step, the right-click menus, its
/// shortcut, `cmux agent fork-conversation-*`). The fork matrix found the palette's Fork hidden in
/// every agent chat (it required a focused terminal), no New Window destination, and a Codex
/// terminal refused as "Claude only" although `codex fork` exists.
@MainActor @Suite(.serialized)
struct ForkConversationTests {
    static let destinations: [(ActionID, AgentForkDestination)] = [
        ("palette.forkAgentConversationRight", .right), ("palette.forkAgentConversationLeft", .left),
        ("palette.forkAgentConversationTop", .up), ("palette.forkAgentConversationBottom", .down),
        ("palette.forkAgentConversationNewTab", .tab), ("palette.forkAgentConversationNewWorkspace", .workspace),
        ("palette.forkAgentConversationNewWindow", .window),
    ]

    static func services() -> AppServices {
        _ = NSApplication.shared
        return AppServices(environment: AppEnvironment.current([:]))
    }

    /// Every destination is a bound action, offered with an agent chat focused as with a terminal.
    @Test func everyDestinationIsOfferedInAnAgentChatAndATerminal() {
        let services = Self.services()
        AppActions.bind(services)
        for (id, _) in Self.destinations {
            #expect(services.registry.unavailableReason(for: id) == nil, "\(id)")
            #expect(services.registry.isAvailable(id, in: [.agentPaneFocused]), "\(id) in an agent chat")
            #expect(services.registry.isAvailable(id, in: [.terminalFocused]), "\(id) in a terminal")
        }
    }

    /// The palette's step lists every destination, the default (right) first.
    @Test func thePaletteStepListsEveryDestinationDefaultFirst() throws {
        let family = try #require(ActionDescriptor.paletteFamilies.first { $0.id == "forkConversation" })
        #expect(family.members == Self.destinations.map(\.0))
        #expect(AgentHandlers.destination(of: family.members[0]) == AgentForkDestination.default)
    }

    @Test func eachActionNamesItsDestination() {
        for (id, destination) in Self.destinations {
            #expect(AgentHandlers.destination(of: id) == destination, "\(id)")
        }
    }

    /// The default destination has a shortcut, shown in Settings and the palette.
    @Test func theDefaultForkHasAShortcut() throws {
        let descriptor = try #require(ActionCatalog.all.first { $0.id == "palette.forkAgentConversationRight" })
        #expect(descriptor.defaultShortcut != nil)
    }

    /// A terminal agent forks by its own CLI: Claude Code and Codex. Others say so.
    @Test(arguments: [
        ("claude", "s-1", "claude --resume s-1 --fork-session"),
        ("Claude_Code", "s-1", "claude --resume s-1 --fork-session"),
        ("codex", "019a-77", "codex fork 019a-77"),
    ])
    func aTerminalAgentForksByItsCLI(agent: String, session: String, command: String) {
        #expect(AgentHandlers.forkCommand(agent: agent, session: session) == command)
    }

    @Test func aTerminalAgentWithoutAForkCommandOrAPlainSessionIsRefused() {
        #expect(AgentHandlers.forkCommand(agent: "opencode", session: "x") == nil)
        #expect(AgentHandlers.forkCommand(agent: "codex", session: "a; rm -rf ~") == nil)
        #expect(AgentHandlers.forkCommand(agent: "claude", session: "") == nil)
    }
}
