#if DEBUG
import AppKit
import CmuxNextPages
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// `debug.agent_pane click` on a chat shown by the shared page host (`agent.pageHost`): the
/// element is found in the page the chat shows, not in the pane's own unused WebKit view, which
/// holds no document (a capture slot answered "no visible element matches" for every selector,
/// even `textarea`, while `chat_state` worked on the same pane).
@Suite(.serialized)
@MainActor
struct AgentPaneDebugClickPageHostTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @Test func clickFindsAnElementOfThePageTheChatShows() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "debug-click-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "index.html")
        let html = #"<html><body><textarea style="width:200px;height:40px"></textarea><button aria-label="Remove red.png" style="position:absolute;left:300px;top:10px;width:16px;height:16px"></button></body></html>"#
        try Data(html.utf8).write(to: file)
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file), pageHost: true))
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        // The page loads in the page host.
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let ready = try? await view.callPageScript("return !!document.querySelector('textarea');") as? Bool
            if ready == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        let field = await view.debugLocate(selector: "textarea", text: "")
        #expect(field["error"] == nil, "\(field)")
        #expect(field["tag"] as? String == "textarea")
        #expect((field["x"] as? Double).map { abs($0 - 108) < 2 } == true, "\(field)")

        let remove = await view.debugLocate(selector: "", text: "Remove red.png")
        #expect(remove["tag"] as? String == "button", "\(remove)")
        #expect((remove["x"] as? Double).map { abs($0 - 308) < 2 } == true, "\(remove)")

        let none = await view.debugLocate(selector: ".missing", text: "")
        #expect(none["error"] as? String == "no visible element matches")
    }
}
#endif
