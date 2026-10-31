import AppKit
import CmuxNextDaemon
import CmuxNextHistory
import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
import Foundation
import Testing

/// Fork Conversation (Cmd-Shift-P's "Fork Conversation…" step, the right-click menus, its
/// shortcut, `cmux agent fork-conversation-*`). The fork matrix found the palette's Fork hidden in
/// every agent chat (it required a focused terminal), no New Window destination, and a Codex
/// terminal refused as "Claude only" although `codex fork` exists; on Oct 29, every
/// hook-reported terminal refused (its id is `agent_session_id`) and Muse refused outright.
@MainActor @Suite(.serialized)
struct ForkConversationTests {
    static let destinations: [(ActionID, AgentForkDestination)] = [
        ("palette.forkAgentConversationRight", .right), ("palette.forkAgentConversationLeft", .left),
        ("palette.forkAgentConversationTop", .up), ("palette.forkAgentConversationBottom", .down),
        ("palette.forkAgentConversationNewColumnRight", .columnRight), ("palette.forkAgentConversationNewColumnLeft", .columnLeft),
        ("palette.forkAgentConversationNewRow", .row),
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
        for (id, destination) in [("palette.forkAgentConversation", AgentForkDestination.default)] + Self.destinations {
            // A new row needs rows on and a daemon with rows-v1, as New Row does; it says so.
            if destination == .row {
                #expect(services.registry.unavailableReason(for: id) == ColumnHandlers.newRowUnavailableReason(AppActionContext(services: services)), "\(id)")
                continue
            }
            #expect(services.registry.unavailableReason(for: id) == nil, "\(id)")
            #expect(services.registry.isAvailable(id, in: [.agentPaneFocused]), "\(id) in an agent chat")
            #expect(services.registry.isAvailable(id, in: [.terminalFocused]), "\(id) in a terminal")
        }
    }

    /// The palette's step lists every destination, the default (right) first.
    @Test func thePaletteFamilyRunsTheDefaultAndKeepsExplicitDestinations() throws {
        let family = try #require(ActionDescriptor.paletteFamilies.first { $0.id == "forkConversation" })
        #expect(family.members == Self.destinations.map(\.0))
        #expect(family.parent == "palette.forkAgentConversation")
        #expect(AgentHandlers.destination(of: try #require(family.parent)) == AgentForkDestination.default)
    }

    @Test func emptySpaceOffersImmediateForkAndSeparateDestinationChoices() throws {
        let services = Self.services()
        AppActions.bind(services)
        let menu = services.registry.makeContextMenu(for: .agentChat, implied: [.agentPaneFocused])
        let title = try #require(ActionCatalog.all.first { $0.id == "palette.forkAgentConversation" }?.title)
        let primary = try #require(menu.items.first { $0.title == title })
        #expect(primary.submenu == nil)
        let destinations = try #require(menu.items.first { $0.submenu?.items.filter { !$0.isSeparatorItem }.count == Self.destinations.count }?.submenu)
        #expect(destinations.items.filter { !$0.isSeparatorItem }.count == Self.destinations.count)
    }

    @Test func eachActionNamesItsDestination() {
        for (id, destination) in Self.destinations {
            #expect(AgentHandlers.destination(of: id) == destination, "\(id)")
        }
    }

    /// The default destination has a shortcut, shown in Settings and the palette.
    @Test func theDefaultForkHasAShortcut() throws {
        let descriptor = try #require(ActionCatalog.all.first { $0.id == "palette.forkAgentConversation" })
        #expect(descriptor.defaultShortcut != nil)
    }

    /// A terminal agent as cmux-tui reports it from its hooks: the harness's own session id in
    /// `agent_session_id`, `session` only a label (cmux-tui `list-agents`).
    static func hooked(_ agent: String?, id: String?, label: String? = "Claude Code") -> AgentStatus {
        AgentStatus(surface: 1, state: .idle, source: "hook", session: label, agent: agent, agentSessionID: id)
    }

    /// A terminal agent whose own CLI forks: Claude Code, Codex, Grok. The fork matrix of Oct 29
    /// found every hook-reported terminal refused ("no agent session"): the fork read `session`.
    @Test(arguments: [
        ("claude", "4b6c20a4-1d7d-411c-ae1a-b1f27e82b482", "claude --resume 4b6c20a4-1d7d-411c-ae1a-b1f27e82b482 --fork-session"),
        ("Claude_Code", "s-1", "claude --resume s-1 --fork-session"),
        ("codex", "01a14344-2fe7-7e33-8f68-5e342115469c", "codex fork 01a14344-2fe7-7e33-8f68-5e342115469c"),
        ("grok", "g-7", "grok --resume g-7 --fork-session"),
    ])
    func aHookedTerminalAgentForksByItsCLI(agent: String, id: String, command: String) {
        #expect(AgentHandlers.terminalFork(Self.hooked(agent, id: id)) == .command(command))
    }

    /// A direct report (no hook) still names its session in `session`.
    @Test func aDirectlyReportedSessionStillForks() {
        let status = AgentStatus(surface: 1, state: .idle, source: "socket", session: "019a-77", agent: "codex")
        #expect(AgentHandlers.terminalFork(status) == .command("codex fork 019a-77"))
    }

    /// Muse's CLI has no fork (`muse resume` only): acpmux forks it through its ACP agent's own
    /// `session/fork`, and the new terminal resumes the fork.
    @Test(arguments: ["muse", "opencode", "gemini"])
    func aTerminalAgentWithoutACLIForkForksThroughACP(agent: String) {
        #expect(AgentHandlers.terminalFork(Self.hooked(agent, id: "01a1802b-9ee5")) == .acp(harness: agent, session: "01a1802b-9ee5"))
    }

    @Test func theForkOfAnACPForkedAgentResumesInTheNewTerminal() {
        #expect(TerminalAgentFork.resumeLine(harness: "muse", session: "00000000-0000-7a49-a7fd-5019018f65db")
            == "muse resume 00000000-0000-7a49-a7fd-5019018f65db")
    }

    @Test func aTerminalWithoutASessionOrAPlainIdOrAKnownAgentIsRefused() {
        #expect(AgentHandlers.terminalFork(nil) == .noSession)
        #expect(AgentHandlers.terminalFork(Self.hooked("codex", id: nil, label: nil)) == .noSession)
        #expect(AgentHandlers.terminalFork(Self.hooked("codex", id: "cmux-hook-sequence:4", label: nil)) == .noSession)
        #expect(AgentHandlers.terminalFork(Self.hooked("codex", id: "a; rm -rf ~")) == .noSession)
        #expect(AgentHandlers.terminalFork(Self.hooked("kiro", id: "x")) == .unsupported)
    }

    /// u18673: every new fork destination is a CLI verb, an MCP tool and a palette row, as the
    /// other destinations are.
    @Test(arguments: ["palette.forkAgentConversationNewColumnRight", "palette.forkAgentConversationNewColumnLeft",
                      "palette.forkAgentConversationNewRow"])
    func aStripDestinationIsOfferedOnEverySurface(id: String) throws {
        let descriptor = try #require(ActionCatalog.all.first { $0.id == ActionID(rawValue: id) })
        #expect(descriptor.cliName.hasPrefix("agent fork-conversation-to-new-"))
        #expect(descriptor.surfacePlan.cli == .offered)
        #expect(descriptor.surfacePlan.mcp == .offered)
        #expect(descriptor.surfacePlan.palette == .offered)
        #expect(!descriptor.surfacePlan.contextMenus.isEmpty)
    }

    /// A terminal agent's fork opens its new terminal where the destination says: a strip column
    /// on either side, or a row below, through the daemon's own new-column and new-row commands.
    @Test func aTerminalForkPlansColumnsAndRows() {
        #expect(TerminalForkPlacement(.columnRight) == .column(left: false))
        #expect(TerminalForkPlacement(.columnLeft) == .column(left: true))
        #expect(TerminalForkPlacement(.row) == .row)
        #expect(TerminalForkPlacement(.right) == .split(down: false, swap: false))
        #expect(TerminalForkPlacement(.up) == .split(down: true, swap: true))
        #expect(TerminalForkPlacement(.tab) == .tab)
        #expect(TerminalForkPlacement(.window) == .workspace)
    }
}
