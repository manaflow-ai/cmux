import AppKit
import CmuxNextActions
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The agent chat's transcript steps at the action boundary: Previous Turn and Next Turn keep their
/// Ctrl-Opt arrow keys, and Previous and Next Bookmarked Prompt are command palette actions with no
/// default key. Each step reaches the page as its own command, which the page turns into the window
/// event the thread minimap handles (App.tsx `command`, ThreadMinimap.tsx).
@Suite(.serialized)
@MainActor
struct AgentPaneTranscriptStepTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// Collects the host events a subscribed page receives.
    private final class Received {
        var events: [JSONValue] = []
    }

    @Test func bookmarkStepsArePaletteActionsWithNoDefaultKey() throws {
        for id in ["agentPane.previousBookmarkedPrompt", "agentPane.nextBookmarkedPrompt"] {
            let descriptor = try #require(ActionCatalog.all.first { $0.id.rawValue == id }, "\(id) is not in the catalog")
            #expect(descriptor.defaultShortcut == nil, "\(id) has a default key")
            #expect(descriptor.surfaces.contains(.palette), "\(id) is not in the command palette")
            #expect(descriptor.requires.contains(.agentPaneFocused))
        }
        // The turn steps keep their keys.
        for id in ["agentPane.previousTurn", "agentPane.nextTurn"] {
            let descriptor = try #require(ActionCatalog.all.first { $0.id.rawValue == id })
            #expect(descriptor.defaultShortcut?.modifiers == [.control, .option])
        }
        // Every step is a catalog action the app binds by its id.
        for step in AgentTranscriptStep.allCases {
            #expect(ActionCatalog.all.contains { $0.id.rawValue == step.actionID }, "\(step.actionID) is not in the catalog")
        }
    }

    @Test func eachStepSendsItsPageCommand() async throws {
        let file = try #require(AgentPageTestRoot.page)
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost(), sessionId: "session-a"), source: .bundled(file), pageHost: true))
        let provider = try #require(view.pageEvents, "the shared page host has no event stream")
        let received = Received()
        let subscription = try await provider.subscribe(
            AgentPageProvider.hostEvents, filter: .null, context: PageCallContext(page: PageDescriptor.agent.id)
        ) { event in received.events.append(event) }
        defer { subscription.cancel() }

        for step in AgentTranscriptStep.allCases { view.step(step) }
        let commands = received.events.filter { $0["kind"] == .string("command") }
        #expect(commands == [
            AgentPageEvent.command("previousTurn").data,
            AgentPageEvent.command("nextTurn").data,
            AgentPageEvent.command("previousBookmarkedPrompt").data,
            AgentPageEvent.command("nextBookmarkedPrompt").data,
        ])
    }

    @Test func stopTurnSendsTheComposerStopCommand() async throws {
        let file = try #require(AgentPageTestRoot.page)
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost(), sessionId: "session-a"), source: .bundled(file), pageHost: true))
        let provider = try #require(view.pageEvents, "the shared page host has no event stream")
        let received = Received()
        let subscription = try await provider.subscribe(
            AgentPageProvider.hostEvents, filter: .null, context: PageCallContext(page: PageDescriptor.agent.id)
        ) { event in received.events.append(event) }
        defer { subscription.cancel() }

        view.stopTurn()

        #expect(received.events.filter { $0["kind"] == .string("stopTurn") } == [
            AgentPageEvent(kind: "stopTurn", value: .string("session-a")).data,
        ])
    }
}
