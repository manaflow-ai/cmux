@testable import CmuxNextApp
import CmuxHomeCore
import CmuxNextActions
import CmuxNextHistory
@testable import CmuxNextHomeEngine
import Foundation
import Testing

/// `cmux chief edit|engine|adopt`, `cmux history remove-site` and `cmux errors clear` have a palette
/// row (cmuxterm-hq goals/palette-all-actions.md: every CLI action has a palette entry). The Chief
/// rows pick from this Mac's Chiefs and agents, where the CLI takes an id; the ones the owner takes
/// only from the person refuse a script.
@MainActor @Suite struct ChiefRegistryPaletteTests {
    @Test func theNewActionsAreInThePaletteAndLeaveTheCLIToItsOwner() throws {
        let registry = ActionRegistry.standard()
        let picks: [ActionID: (String, String)] = [
            "home.editChief": ("chief", ActionSuggestions.localChiefs),
            "home.setChiefModel": ("chief", ActionSuggestions.localChiefs),
            "home.setChiefEffort": ("chief", ActionSuggestions.localChiefs),
            "home.adoptChief": ("agent", ActionSuggestions.adoptableAgents),
        ]
        for id in Array(picks.keys) + ["history.removeSite", "help.clearErrorLog"] {
            let descriptor = try #require(registry.descriptor(for: id), "\(id)")
            #expect(descriptor.isPaletteVisible, "\(id)")
            #expect(descriptor.surfacePlan.cli == .exempt(.ownerVerb), "\(id)")
            if let (argument, source) = picks[id] {
                #expect(descriptor.arguments.first { $0.name == argument }?.suggestions?.source == source, "\(id)")
            }
        }
        for id: ActionID in ["home.adoptChief", "home.setChiefModel", "home.setChiefEffort"] {
            #expect(registry.descriptor(for: id)?.isPersonOnly == true, "\(id)")
        }
        let efforts = registry.descriptor(for: "home.setChiefEffort")?.arguments.first { $0.name == "effort" }
        guard case .enumeration(let cases)? = efforts?.kind else { Issue.record("effort is no enumeration"); return }
        #expect(cases.map(\.value) == ["low", "medium", "high", "xhigh", "max", "default"])
    }

    @Test func thePicksListThisMacsChiefsAndTheAgentsThatAreNone() {
        let me = Participant(id: ParticipantID("user_local"), kind: .human, displayName: "Me")
        let ada = Participant(id: ParticipantID("agent_mux"), kind: .agent, displayName: "Ada", agentClass: .chief)
        let muse = Participant(id: ParticipantID("agent_muse"), kind: .agent, displayName: "Muse", agentClass: .chief)
        let gone = Participant(id: ParticipantID("agent_gone"), kind: .agent, displayName: "Gone", agentClass: .chief)
        let coder = Participant(id: ParticipantID("agent_codex_1"), kind: .agent, displayName: "Codex", agentClass: .agent)
        let rows = [row("conv_1", [me, ada, coder]), row("conv_2", [me, muse]), row("conv_3", [me, ada, gone, coder])]
        #expect(HomeChiefPicks(rows).localChiefs(deleted: ["agent_gone"])
            == [ActionEnumCase(value: "agent_mux", title: "Ada"), ActionEnumCase(value: "agent_muse", title: "Muse")])
        #expect(HomeChiefPicks(rows).adoptableAgents() == [ActionEnumCase(value: "agent_codex_1", title: "Codex")])
    }

    @Test func idsAndSitesAreReadTheWayTheOwnerTakesThem() {
        #expect(HomeChiefRegistryActions.id(" agent_muse ") == "agent_muse")
        #expect(HomeChiefRegistryActions.id("agent/../x") == nil)
        #expect(HomeChiefRegistryActions.id("") == nil)
        #expect(HistorySite("Example.com")?.host == "example.com")
        #expect(HistorySite("https://news.example.com/a?b=1")?.host == "news.example.com")
        #expect(HistorySite("not a host")?.host == nil)
        #expect(HistorySite(nil)?.host == nil)
    }

    private func row(_ id: String, _ participants: [Participant]) -> CmuxHomeCore.ConversationSummary {
        CmuxHomeCore.ConversationSummary(id: ConversationID(id), owner: .local, participants: participants, createdAt: .distantPast, updatedAt: .distantPast)
    }
}
