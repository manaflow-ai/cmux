import AppKit
@testable import CmuxHomeCore
import CmuxNextDesign
@testable import CmuxNextHome
import Foundation
@testable import MessagesLabHome
import Testing

/// A Chief opened from Home's list for the first time opens at its newest message
/// (https://github.com/manaflow-ai/cmux/issues/26397), through the app's transcript view
/// (`HomeNativeTranscriptView`: its binding, header and first-run panel) in an on-screen window:
/// the view is made while nothing holds the conversation open, its first page arrives after it is
/// up, then what the app does next follows (the message box takes the keyboard, the header's panel
/// toggles arrive, the window is resized). After each step the transcript must still rest at the
/// bottom; each step's offsets are printed, so a failure names the step that moved it.
@MainActor @Suite(.serialized) struct HomeColdOpenAtNewestTests {
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

    private func check(_ view: HomeNativeTranscriptView, _ step: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let demo = try #require(view.transcript.controller.demo, "\(step): no transcript", sourceLocation: sourceLocation)
        let state = demo.store.state
        let y = demo.collection.contentOffset.y
        let clip = demo.superview.map { _ in view.transcript.controller.host.scrollView.contentView.bounds.origin.y } ?? .nan
        print("26397 \(step): messages=\(state.conversation.messages.count) pinned=\(state.ui.scroll.pinnedToBottom) atNewest=\(state.atNewest) offset=\(y) bottom=\(demo.pinnedOffset) top=\(demo.minOffset) clip=\(clip)")
        #expect(!state.conversation.messages.isEmpty, "\(step): the first page is in", sourceLocation: sourceLocation)
        #expect(demo.pinnedOffset - demo.minOffset > 100, "\(step): the chat is taller than the window", sourceLocation: sourceLocation)
        #expect(state.ui.scroll.pinnedToBottom, "\(step): not pinned to the newest message", sourceLocation: sourceLocation)
        #expect(abs(y - demo.pinnedOffset) < 1, "\(step): offset \(y), bottom \(demo.pinnedOffset), top \(demo.minOffset)",
                sourceLocation: sourceLocation)
    }

    @Test func aChiefOpenedFromTheListForTheFirstTimeOpensAtItsNewestMessage() async throws {
        _ = NSApplication.shared
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(HomeTunables.all)
        var options = MockHomeSource.Options.immediate
        options.chiefHistory = 400
        let source = GatedHomeSource(MockHomeSource(options: options))
        let store = HomeStore(source: source)
        store.start()
        defer { store.stop() }
        await until { store.me != nil && store.isOnline }
        let me = try #require(store.me?.id)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 800), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 800))
        window.contentView = container
        window.orderFrontRegardless()

        // Nothing holds the Chief open: its first page read waits until the view is up.
        source.hold()
        let view = HomeNativeTranscriptView(store: store, conversation: Self.conversation, me: me)
        defer { view.stop() }
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        container.layoutSubtreeIfNeeded()
        await until { source.waiting > 0 }
        #expect(source.waiting == 1, "the first page read waits")
        pass(window, view)

        source.release()
        await until { !store.transcript(for: Self.conversation).isEmpty }
        await settle()
        pass(window, view)
        try check(view, "first page in")

        view.takeKeyboardOnOpen()
        await settle()
        pass(window, view)
        try check(view, "message box took the keyboard")

        view.setHeaderPanels([HomeHeaderPanelItem(id: "memory", symbol: "brain", label: "Memory Inspector", isOn: false)])
        pass(window, view)
        try check(view, "header panel toggles arrived")

        window.setContentSize(NSSize(width: 760, height: 700))
        await settle()
        pass(window, view)
        try check(view, "window resized")

        await settle()
        pass(window, view)
        try check(view, "a pass later")
    }
}
