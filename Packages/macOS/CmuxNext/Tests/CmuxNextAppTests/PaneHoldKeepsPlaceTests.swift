import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextTabs
import Foundation
import Testing

/// A paint hold keeps the outgoing page where it showed in the pane. A chat whose tools share the tab row fills the
/// whole pane; a New Tab page sits under the strip. The content area takes the incoming page's frame at the switch, and
/// the outgoing page it keeps followed it: the chat moved down by the strip's height with its transcript and composer
/// laid out at the old height (the composer cut off at the bottom), and back on the chat it drew one frame laid out at
/// the shorter height before it snapped down (Leo 2026-11-15: "there is layout shift here... why...").
@MainActor @Suite(.serialized) struct PaneHoldKeepsPlaceTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private func page(_ file: URL) throws -> AgentPaneView {
        try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file)))
    }

    /// The view's frame in the pane's coordinates.
    private func place(of view: NSView, in pane: PaneContentView) -> NSRect {
        pane.convert(view.frame, from: view.superview)
    }

    @Test func aKeptPageKeepsItsPlaceWhenTheTabRowChangesHands() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "hold-place-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "index.html")
        try Data("<html><body>Chat</body></html>".utf8).write(to: file)
        let chat = try page(file)
        defer { chat.close() }
        let newTab = try page(file)
        defer { newTab.close() }
        let nextChat = try page(file)
        defer { nextChat.close() }
        let tabs = [TabItem(id: TabID("chat"), title: "Chat"), TabItem(id: TabID("new"), title: "New Tab"),
                    TabItem(id: TabID("next"), title: "Chat 2")]
        let pane = PaneContentView(stripModel: TabStripModel(tabs: tabs), reveal: LaunchReveal(deadline: .zero))
        pane.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        try #require(pane.stripHeight > 0)

        // The chat's header tools share the tab row: it fills the whole pane.
        pane.show(chat)
        chat.model.markPainted()
        chat.model.tabRow.report(width: 120)
        pane.needsLayout = true
        pane.layoutSubtreeIfNeeded()
        let chatPlace = place(of: chat, in: pane)
        try #require(chatPlace == pane.bounds, "the chat sharing the row fills the pane")

        // To the New Tab page: the chat stays shown until it paints, where it was and at its size.
        pane.show(newTab)
        try #require(pane.paintHold.kept === chat)
        pane.needsLayout = true
        pane.layoutSubtreeIfNeeded()
        #expect(place(of: chat, in: pane) == chatPlace, "the kept chat moved or resized before the New Tab page painted")
        newTab.model.markPainted()
        #expect(pane.paintHold.kept == nil)
        pane.needsLayout = true
        pane.layoutSubtreeIfNeeded()
        let newTabPlace = place(of: newTab, in: pane)
        #expect(newTabPlace.minY == pane.stripHeight, "the New Tab page sits under the strip")
        #expect(chat.frame.size == chatPlace.size, "the parked chat changed size")

        // To a chat that has not painted: the New Tab page stays where it was until the chat paints.
        nextChat.model.tabRow.report(width: 120)
        pane.show(nextChat)
        try #require(pane.paintHold.kept === newTab)
        pane.needsLayout = true
        pane.layoutSubtreeIfNeeded()
        #expect(place(of: newTab, in: pane) == newTabPlace, "the kept New Tab page moved or resized before the chat painted")
        nextChat.model.markPainted()
        #expect(pane.paintHold.kept == nil)
        pane.needsLayout = true
        pane.layoutSubtreeIfNeeded()
        #expect(place(of: nextChat, in: pane) == pane.bounds, "the incoming chat sharing the row fills the pane")

        // Back to the first chat: it shows where and at the size it showed before.
        pane.show(chat)
        pane.needsLayout = true
        pane.layoutSubtreeIfNeeded()
        #expect(place(of: chat, in: pane) == chatPlace, "the chat came back at another place or size")
    }
}
