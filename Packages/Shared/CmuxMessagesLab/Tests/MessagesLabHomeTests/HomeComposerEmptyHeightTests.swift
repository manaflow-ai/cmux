import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// User, 2026-11-16 (the Chief chat in Home): "when imessage chat text input is empty, then i type
/// into, and height of the input increases by just slightly". An empty field and a one-line draft
/// are one line, so the field keeps its height to the device pixel when the first character comes
/// and when the last one goes, also right after a send (the case that grew 1 pt on macOS 27). The
/// real view over a real `HomeStore` on the mock owner, in an offscreen window, light and dark;
/// text goes in through the field's `insertText` (the path a key takes) and the send is the send
/// button's press (the path Return takes).
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct HomeComposerEmptyHeightTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    static let conversation = ConversationID("conv_chief")

    struct Harness {
        let store: HomeStore
        let window: NSWindow
        let view: MessagesLabHomeView
        let field: NSTextView
        let compose: ComposeView
    }

    private func until(_ condition: @escaping @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else { Issue.record("the condition never held"); return }
            await Task.yield()
        }
    }

    private func makeHarness(_ appearance: NSAppearance.Name) async throws -> Harness {
        // The field takes its height at once: the heights are what these tests read, not the spring.
        MessagesLabHomeView.reduceMotionOverride = true
        let options = MockHomeSource.Options(chiefHistory: 20, latency: .zero, replyDelay: .seconds(3600))
        let store = HomeStore(source: MockHomeSource(options: options))
        store.start()
        await until { store.me != nil && store.isOnline }
        await store.open(Self.conversation)
        await until { !store.transcript(for: Self.conversation).isEmpty }
        let me = try #require(store.me?.id)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 900), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        let view = MessagesLabHomeView(store: store, conversation: Self.conversation, me: me, wake: NoWake())
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        window.contentView = view
        view.projection.refresh()
        view.layoutSubtreeIfNeeded()
        let maybeCompose = view.controller.demo?.compose
        try #require(maybeCompose != nil)
        let compose = maybeCompose!
        return Harness(store: store, window: window, view: view, field: compose.textView.view, compose: compose)
    }

    private func close(_ h: Harness) {
        h.view.stop(); h.window.close(); h.store.stop()
        MessagesLabHomeView.reduceMotionOverride = nil
    }

    private func settle(_ h: Harness) async {
        for _ in 0..<8 { await Task.yield() }
        h.window.contentView?.layoutSubtreeIfNeeded()
    }

    private func type(_ h: Harness, _ text: String) async {
        h.field.insertText(text, replacementRange: h.field.selectedRange())
        await settle(h)
    }

    private func clear(_ h: Harness) async {
        h.field.selectAll(nil)
        h.field.deleteBackward(nil)
        await settle(h)
    }

    private static func sendButton(_ root: NSView) -> NSView? {
        var views: [NSView] = [root]
        while let v = views.popLast() {
            if v.accessibilityIdentifier() == "cmux.home.composer.send" { return v }
            views += v.subviews
        }
        return nil
    }

    /// The field's frame in device pixels (the window's backing scale), so a half-point step shows.
    private func fieldPixels(_ h: Harness) -> (top: CGFloat, height: CGFloat) {
        let scale = h.window.backingScaleFactor
        let field = h.compose.fieldRect
        return ((field.minY * scale).rounded(), (field.height * scale).rounded())
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func emptyAndOneLineAreTheSameHeightBeforeAndAfterASend(_ appearance: NSAppearance.Name) async throws {
        let h = try await makeHarness(appearance)
        defer { close(h) }
        let scale = h.window.backingScaleFactor

        let opened = fieldPixels(h)
        await type(h, "a")
        let firstLetter = fieldPixels(h)
        #expect(firstLetter == opened, "an empty field (never sent from) and its first letter: \(opened) vs \(firstLetter) px at \(scale)x")
        await clear(h)
        let cleared = fieldPixels(h)
        #expect(cleared == opened, "Backspace back to empty: \(opened) vs \(cleared) px")

        await type(h, "hello from the first message")
        let found = Self.sendButton(h.view)
        try #require(found != nil, "the composer has a send button")
        let pressed = found!.accessibilityPerformPress()
        #expect(pressed)
        await until { h.store.transcript(for: Self.conversation).contains { $0.parts == [.text("hello from the first message")] } }
        await until { h.field.string.isEmpty }
        await settle(h)
        let afterSend = fieldPixels(h)
        #expect(afterSend == opened, "the empty field after a send is the one-line height: \(opened) vs \(afterSend) px")
        await type(h, "H")
        let typedAfterSend = fieldPixels(h)
        #expect(typedAfterSend == afterSend, "the first letter after a send keeps the height: \(afterSend) vs \(typedAfterSend) px")
        await clear(h)
        let clearedAfterSend = fieldPixels(h)
        #expect(clearedAfterSend == typedAfterSend, "Backspace after a send keeps it: \(typedAfterSend) vs \(clearedAfterSend) px")
    }
}
