import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing
import WebKit
@testable import CmuxNextAgentPane

/// `/btw` behind Debug Settings' Side sessions (/btw) (`agentPane.debug.sideSessions`, off by default): with the
/// toggle off the palette has no Ask a Side Question… and the page is told side sessions are off
/// (no `/btw`); with it on the palette offers the action in a focused agent chat, the page is told
/// they are on, and running the action sends the chat's page the `sideQuestion` command, which
/// prefills `/btw ` in its composer.
@Suite(.serialized)
@MainActor
struct AgentPaneSideQuestionPaletteTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private static let id: ActionID = "agentPane.sideQuestion"

    /// Runs `body` with the toggle set to `on`, then resets it.
    private func withSideSessions(_ on: Bool, _ body: () async throws -> Void) async throws {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(AgentPaneTunables.all)
        TunableStore.shared.set(AgentPaneTunables.sideSessions.key, on ? .bool(true) : nil)
        defer { TunableStore.shared.set(AgentPaneTunables.sideSessions.key, nil) }
        try await body()
    }

    @Test func offByDefaultThePaletteHasNoSideQuestionAndThePageNoBtw() async throws {
        try await withSideSessions(false) {
            let registry = ActionRegistry.standard()
            registry.context = [.agentPaneFocused]
            registry.publishSideSessions()
            #expect(!registry.context.contains(.sideSessions))
            #expect(!registry.isAvailable(Self.id), "Ask a Side Question… offered while Side sessions is off")
            #expect(AgentPaneHeaderState().json.objectValue?["sideSessions"] == .bool(false), "the page is not told side sessions are off")
        }
    }

    @Test func onThePaletteOffersASideQuestionInAFocusedAgentChatAndThePageBtw() async throws {
        try await withSideSessions(true) {
            let registry = ActionRegistry.standard()
            let descriptor = try #require(registry.descriptor(for: Self.id), "no Ask a Side Question… action")
            #expect(descriptor.surfaces.contains(.palette))
            #expect(descriptor.defaultShortcut == nil, "a default key needs a call")
            registry.context = [.agentPaneFocused]
            registry.publishSideSessions()
            #expect(registry.context.contains(.sideSessions))
            #expect(registry.isAvailable(Self.id), "Ask a Side Question… missing while Side sessions is on")
            #expect(!registry.isAvailable(Self.id, in: [.sideSessions]), "offered outside an agent chat")
            #expect(AgentPaneHeaderState().json.objectValue?["sideSessions"] == .bool(true), "the page is not told side sessions are on")
        }
    }

    @Test func turningTheToggleOffHidesTheActionAgainWithoutReopening() async throws {
        try await withSideSessions(true) {
            let registry = ActionRegistry.standard()
            registry.context = [.agentPaneFocused]
            registry.publishSideSessions()
            #expect(registry.isAvailable(Self.id))
            TunableStore.shared.set(AgentPaneTunables.sideSessions.key, nil)
            for _ in 0..<50 where registry.isAvailable(Self.id) { try await Task.sleep(for: .milliseconds(20)) }
            #expect(!registry.isAvailable(Self.id), "the palette still offers it after the toggle went off")
        }
    }

    @Test func runningItSendsTheFocusedChatsPageTheSideQuestionCommand() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "side-question-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "index.html")
        let page = "<html><body><script>window.commands = []; window.cmuxAcpmuxBridge = { command(c) { window.commands.push(c); } };</script></body></html>"
        try Data(page.utf8).write(to: file)
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file)))
        for _ in 0..<50 where (try? await view.webView.evaluateJavaScript("typeof window.cmuxAcpmuxBridge") as? String) != "object" {
            try await Task.sleep(for: .milliseconds(100))
        }

        view.askSideQuestion()
        var commands: [String] = []
        for _ in 0..<50 {
            commands = (try? await view.webView.evaluateJavaScript("window.commands.join(',')") as? String)?
                .split(separator: ",").map(String.init) ?? []
            if !commands.isEmpty { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(commands == ["sideQuestion"])
    }
}
