import CmuxNextActions
import Foundation
import Testing
import WebKit
@testable import CmuxNextAgentPane

/// `/btw` from the command palette: Ask a Side Question… is offered in the palette only while an
/// agent chat has focus, takes no default key (default hotkeys need a call), and running it sends
/// the focused chat's page the `sideQuestion` command, which starts a side question in its
/// composer (a page whose side sessions gate is off ignores it).
@Suite(.serialized)
@MainActor
struct AgentPaneSideQuestionPaletteTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @Test func thePaletteOffersASideQuestionOnlyInAFocusedAgentChat() throws {
        let registry = ActionRegistry.standard()
        let descriptor = try #require(registry.descriptor(for: "agentPane.sideQuestion"), "no Ask a Side Question… action")
        #expect(descriptor.surfaces.contains(.palette))
        #expect(descriptor.defaultShortcut == nil, "a default key needs a call")
        #expect(registry.isAvailable("agentPane.sideQuestion", in: [.agentPaneFocused]))
        #expect(!registry.isAvailable("agentPane.sideQuestion", in: []), "offered outside an agent chat")
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
