import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextTestSupport
import Testing

/// The chat zoom of Lawrence's 2026-11-23 film (a Chief chat beside a browser pane): the chat's page on the Chromium
/// engine draws in Chromium's child window, which the pane's moving clip does not cut. A pane that shows that chat does
/// not ride: a zoom or an unzoom of it shows in one frame, so the panes under it never show through it. The same chat
/// on WebKit (in its own layer) rides. A browser pane's page needs no such rule: it is layer hosted
/// (`CEFLayerHosting`), so the clip cuts it.
@MainActor @Suite(.closesItsWindows, .serialized)
struct PaneContentRidesChatInChromiumTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// A pane content's area that shows a chat on the Chromium engine (`chromium` true) or on WebKit, laid out.
    private func chatPane(chromium: Bool) async throws -> (content: NSView, chat: AgentPaneView, folder: URL) {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appending(path: "chat-rides-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "index.html")
        try Data("<html><body><textarea></textarea></body></html>".utf8).write(to: file)
        let chat = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file), pageHost: true,
                                              testRoot: true, chromium: chromium ? FakeChromiumHosting() : nil))
        if let start = chat.page?.chromiumStart { await start.value }
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let area = PaneContentAreaView(frame: content.bounds)
        content.addSubview(area)
        chat.frame = area.bounds
        area.addSubview(chat)
        chat.layoutSubtreeIfNeeded()
        #expect(chat.debugShowsChromium == chromium, "SETUP: the chat does not show on the engine asked for")
        return (content, chat, folder)
    }

    @Test func aPaneWhoseChatDrawsInChromiumsWindowDoesNotRide() async throws {
        let (content, chat, folder) = try await chatPane(chromium: true)
        defer { chat.close(); try? FileManager.default.removeItem(at: folder) }
        #expect(!content.paneRidesCommitMotion,
                "a pane that shows a chat in Chromium's window rides: the move's clip does not cut that window, and the panes under it show through")
    }

    @Test func aPaneWhoseChatDrawsInItsOwnLayerRides() async throws {
        let (content, chat, folder) = try await chatPane(chromium: false)
        defer { chat.close(); try? FileManager.default.removeItem(at: folder) }
        #expect(content.paneRidesCommitMotion, "a pane that shows a chat on WebKit does not ride")
    }
}
