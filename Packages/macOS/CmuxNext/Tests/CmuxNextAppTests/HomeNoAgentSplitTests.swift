import AppKit
import CmuxHomeCore
@testable import CmuxNextHome
import CmuxNextTestSupport
@testable import MessagesLabHome
import Testing

/// Home never splits for an agent (user 2026-11-07, msg 23836: "we need to get rid of the imessage home split
/// pane completely"). A click on an agent's pill opens the agent's own workspace through the Chief's link to
/// its session (``HomeNativeTranscriptView/onAppLink``); with no link yet (a queued agent) nothing opens inside
/// Home: the Chief chat keeps the whole width and no column is added beside it.
/// Drives the real `HomeNativeTranscriptView` over a `HomeStore` on the mock owner, through the pill's own
/// callback, in an offscreen window that is never ordered front.
@MainActor @Suite(.serialized, .closesItsWindows) struct HomeNoAgentSplitTests {
    private func home() async throws -> (window: NSWindow, store: HomeStore, view: HomeNativeTranscriptView) {
        let source = MockHomeSource(options: .immediate)
        let store = HomeStore(source: source)
        store.start()
        let inbox = try await source.inbox()
        let chief = await source.chief.id
        let id = try #require((inbox.conversations.first { $0.participants.contains { $0.id == chief } } ?? inbox.conversations.first)?.id)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let view = HomeNativeTranscriptView(store: store, conversation: id, me: inbox.me.id)
        view.frame = try #require(window.contentView).bounds
        window.contentView?.addSubview(view)
        await view.binding.opened()
        view.layoutSubtreeIfNeeded()
        return (window, store, view)
    }

    @Test(arguments: [false, true])
    func aPillClickWithNoWorkspaceNeverSplitsHome(hosted: Bool) async throws {
        let (window, store, view) = try await home()
        defer {
            view.stop()
            store.stop()
            window.close()
        }
        var opened: [URL] = []
        if hosted { view.onAppLink = { opened.append($0) } }
        let before = view.subviews.map(ObjectIdentifier.init)
        let click = try #require(view.transcript.onAgentPill)
        click("a1034", .zero)
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        #expect(view.subviews.map(ObjectIdentifier.init) == before, "a pill click added a column to Home")
        #expect(view.transcript.frame.width == view.bounds.width, "the Chief chat lost width to a split: \(view.transcript.frame.width) of \(view.bounds.width)")
        #expect(opened.isEmpty)
    }
}
