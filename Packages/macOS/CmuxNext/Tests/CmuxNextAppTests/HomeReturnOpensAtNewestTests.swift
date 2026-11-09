import AppKit
@testable import CmuxHomeCore
import CmuxNextDesign
@testable import CmuxNextHome
@testable import CmuxNextHomeModel
import Foundation
@testable import MessagesLabHome
import CmuxNextTestSupport
import Testing

/// Returning to a Chief chat the person had scrolled up in opens it at its newest message
/// (https://github.com/manaflow-ai/cmux/issues/34562), through the app's transcript view in an
/// on-screen window. The docked Home and a conversation tab keep their view while another tab
/// shows: it leaves the window and comes back, or is hidden and shown again. Before the fix, both
/// showed the chat where it was left, in the middle of its history.
@MainActor @Suite(.serialized, .closesItsWindows) struct HomeReturnOpensAtNewestTests {
    static let conversation = ConversationID("conv_chief")

    private func until(_ condition: () -> Bool) async {
        for _ in 0..<20_000 where !condition() { await Task.yield() }
    }

    private func settle() async {
        for _ in 0..<2_000 { await Task.yield() }
    }

    private func pass(_ window: NSWindow, _ view: HomeNativeTranscriptView) {
        view.transcript.projection.refresh()
        window.contentView?.layoutSubtreeIfNeeded()
        view.transcript.controller.demo?.collection.layoutIfNeeded()
        CATransaction.flush()
    }

    private func place(_ view: HomeNativeTranscriptView, _ step: String) throws -> (pinned: Bool, back: CGFloat) {
        let demo = try #require(view.transcript.controller.demo, "\(step): no transcript")
        let back = demo.pinnedOffset - demo.collection.contentOffset.y
        let pinned = demo.store.state.ui.scroll.pinnedToBottom
        print("34562 \(step): returnPins=\(view.returnPins) messages=\(demo.store.state.conversation.messages.count) pinned=\(pinned) back=\(back) bottom=\(demo.pinnedOffset) top=\(demo.minOffset)")
        return (pinned, back)
    }

    private func expectAtNewest(_ view: HomeNativeTranscriptView, _ step: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let p = try place(view, step)
        #expect(p.pinned, "\(step): not pinned to the newest message", sourceLocation: sourceLocation)
        #expect(abs(p.back) < 1, "\(step): \(p.back) pt above the newest message", sourceLocation: sourceLocation)
    }

    private func scrollUp(_ window: NSWindow, _ view: HomeNativeTranscriptView, _ step: String) async throws {
        view.transcript.debugScroll(by: -1500)
        await settle()
        pass(window, view)
        let p = try place(view, step)
        #expect(!p.pinned && p.back > 500, "\(step): the person's scroll took the chat up its history")
    }

    @Test func aChatScrolledUpReturnsAtItsNewestMessage() async throws {
        _ = NSApplication.shared
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(HomeTunables.all)
        var options = MockHomeSource.Options.immediate
        options.chiefHistory = 400
        let store = HomeStore(source: MockHomeSource(options: options))
        store.start()
        defer { store.stop() }
        await until { store.me != nil && store.isOnline }
        let me = try #require(store.me?.id)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 800), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.closeAfterTest() }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 800))
        window.contentView = container
        window.orderFrontRegardless()

        let view = HomeNativeTranscriptView(store: store, conversation: Self.conversation, me: me)
        defer { view.stop() }
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        await until { !store.transcript(for: Self.conversation).isEmpty }
        await settle()
        pass(window, view)
        try expectAtNewest(view, "opened")

        // Another tab takes the pane: the kept view leaves the window, then comes back.
        try await scrollUp(window, view, "scrolled up before leaving")
        view.removeFromSuperview()
        await settle()
        container.addSubview(view)
        await settle()
        pass(window, view)
        try expectAtNewest(view, "back in the window")

        // A container hides it while another view shows, then shows it again.
        try await scrollUp(window, view, "scrolled up before hiding")
        view.isHidden = true
        await settle()
        view.isHidden = false
        await settle()
        pass(window, view)
        try expectAtNewest(view, "shown again")

        // The window's Chief panel borrows the chat beside a link it opened: the link's workspace shows and
        // Home is parked hidden, then the chat's host moves out of it into the visible panel in one turn
        // (WindowRootView.show, ChiefPanelView.hold moves `HomeHostView`). It stays on screen, so the reader
        // keeps their place.
        let home = NSView(frame: container.bounds)
        container.addSubview(home)
        let host = NSView(frame: container.bounds)
        home.addSubview(host)
        view.removeFromSuperview()
        view.frame = host.bounds
        host.addSubview(view)
        await settle()
        pass(window, view)
        try await scrollUp(window, view, "scrolled up before the Chief panel takes it")
        let before = try place(view, "before the Chief panel takes it").back
        let panel = NSView(frame: container.bounds)
        container.addSubview(panel)
        home.isHidden = true
        _ = try place(view, "parked hidden")
        host.removeFromSuperview()
        _ = try place(view, "out of the parked Home")
        panel.addSubview(host)
        _ = try place(view, "into the Chief panel, same turn")
        await settle()
        pass(window, view)
        let held = try place(view, "in the Chief panel")
        #expect(!held.pinned && abs(held.back - before) < 1, "in the Chief panel: \(held.back) pt up, was \(before)")

        // The panel gives it back to Home (shown again in the same turn): still the reader's place.
        host.removeFromSuperview()
        home.addSubview(host)
        home.isHidden = false
        await settle()
        pass(window, view)
        let back = try place(view, "given back to Home")
        #expect(!back.pinned && abs(back.back - before) < 1, "given back to Home: \(back.back) pt up, was \(before)")

        // Cmd-I opens the panel from a Home parked in an earlier turn: the person had not seen the chat, so it
        // arrives at its newest message.
        home.isHidden = true
        await settle()
        host.removeFromSuperview()
        panel.addSubview(host)
        await settle()
        pass(window, view)
        try expectAtNewest(view, "Cmd-I from a parked Home")
    }
}
