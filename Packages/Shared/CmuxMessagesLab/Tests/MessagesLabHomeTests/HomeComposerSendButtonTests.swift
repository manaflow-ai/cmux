import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// The Home composer's send button (user, 2026-10-20: "I want there to be a send button that I can
/// click in the iMessage UI ... if there are multiple lines in the input, this is still handled
/// extremely well"). The real view over a real `HomeStore` on the mock owner, in an offscreen
/// window; text goes in through the field's `insertText` (the path a key takes). The button is found
/// by its accessibility identifier, so these tests read only what VoiceOver and the pointer see.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct HomeComposerSendButtonTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    static let conversation = ConversationID("conv_chief")
    static let identifier = "cmux.home.composer.send"

    struct Harness {
        let store: HomeStore
        let window: NSWindow
        let view: MessagesLabHomeView
        let field: NSTextView
    }

    private func until(_ condition: @escaping @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else { Issue.record("the condition never held"); return }
            await Task.yield()
        }
    }

    private func makeHarness() async throws -> Harness {
        // Animations are not what these tests check: the button is placed at once.
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
        let view = MessagesLabHomeView(store: store, conversation: Self.conversation, me: me, wake: NoWake())
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        window.contentView = view
        view.projection.refresh()
        view.layoutSubtreeIfNeeded()
        let maybeField = view.controller.demo?.compose.textView.view
        try #require(maybeField != nil)
        let field = maybeField!
        return Harness(store: store, window: window, view: view, field: field)
    }

    private func close(_ h: Harness) {
        h.view.stop(); h.window.close(); h.store.stop()
        MessagesLabHomeView.reduceMotionOverride = nil
    }

    private static func find(_ root: NSView) -> NSView? {
        var views: [NSView] = [root]
        while let v = views.popLast() {
            if v.accessibilityIdentifier() == identifier { return v }
            views += v.subviews
        }
        return nil
    }

    private func type(_ h: Harness, _ text: String) async {
        h.field.insertText(text, replacementRange: h.field.selectedRange())
        for _ in 0..<8 { await Task.yield() }
        h.window.contentView?.layoutSubtreeIfNeeded()
    }

    private func clear(_ h: Harness) async {
        h.field.selectAll(nil)
        h.field.deleteBackward(nil)
        for _ in 0..<8 { await Task.yield() }
        h.window.contentView?.layoutSubtreeIfNeeded()
    }

    /// Shown means: an accessibility element, unhidden, and it takes the pointer at its centre.
    private static func shown(_ b: NSView) -> Bool {
        guard b.isAccessibilityElement(), !b.isHidden, b.alphaValue > 0 else { return false }
        // hitTest takes a point in the superview's coordinates (the button's frame).
        return b.hitTest(CGPoint(x: b.frame.midX, y: b.frame.midY)) != nil
    }

    @Test func theButtonAppearsOnlyWithText() async throws {
        let h = try await makeHarness()
        defer { close(h) }
        // Values only in the expectations: Swift Testing reflects a captured view deeply (and traps on its pasteboard).
        let found = Self.find(h.view)
        try #require(found != nil, "the composer has a send button")
        let button = found!
        let emptyShown = Self.shown(button)
        #expect(!emptyShown, "an empty field shows the voice glyph, not the send button")
        await type(h, "hi")
        let typedShown = Self.shown(button)
        #expect(typedShown, "typed text shows the send button")
        let isButton = button.accessibilityRole() == .button
        let labelled = button.accessibilityLabel()?.isEmpty == false
        let size = button.frame.size
        #expect(isButton)
        #expect(labelled)
        #expect(size.width >= 28 && size.height >= 28, "hit target at least 28 pt")
        await clear(h)
        let clearedShown = Self.shown(button)
        #expect(!clearedShown, "an emptied field hides it again")
    }

    @Test func aClickSendsExactlyLikeReturn() async throws {
        let h = try await makeHarness()
        defer { close(h) }
        let found = Self.find(h.view)
        try #require(found != nil)
        let button = found!
        await type(h, "hello from the button")
        let pressed = button.accessibilityPerformPress()
        #expect(pressed)
        await until {
            h.store.transcript(for: Self.conversation).contains { $0.parts == [.text("hello from the button")] }
        }
        let emptied = h.field.string.isEmpty
        #expect(emptied, "the field empties after the send, as after Return")
        h.window.contentView?.layoutSubtreeIfNeeded()
        let stillShown = Self.shown(button)
        #expect(!stillShown)
    }

    @Test func spacesOnlyShowADisabledButtonThatSendsNothing() async throws {
        let h = try await makeHarness()
        defer { close(h) }
        let found = Self.find(h.view)
        try #require(found != nil)
        let button = found!
        let before = h.store.transcript(for: Self.conversation).count
        await type(h, "   ")
        let enabled = button.isAccessibilityEnabled()
        #expect(!enabled)
        _ = button.accessibilityPerformPress()
        for _ in 0..<20 { await Task.yield() }
        let after = h.store.transcript(for: Self.conversation).count
        let text = h.field.string
        #expect(after == before)
        #expect(text == "   ", "nothing to send: the text stays")
    }

    /// Lawrence 2026-10-23: "make right and bottom padding the same". The drawn disc (24 pt in the
    /// 28 pt hit target) sat 5.5 pt from the field's right edge and 3.5 pt from its bottom. Measured
    /// in the real view, in the host's coordinates, for a one-line and a many-line draft.
    @Test func theDiscHasTheSameGapToTheFieldsRightAndBottomEdges() async throws {
        let h = try await makeHarness()
        defer { close(h) }
        let maybeCompose = h.view.controller.demo?.compose
        try #require(maybeCompose != nil)
        let compose = maybeCompose!
        let found = Self.find(h.view)
        try #require(found != nil)
        let button = found!
        let inset = (ComposeSendButton.target - ComposeSendButton.diameter) / 2
        for text in ["a", "\nline two\nline three\nline four"] {
            await type(h, text)
            let field = compose.fieldRect
            let disc = button.frame.insetBy(dx: inset, dy: inset)
            let right = field.maxX - disc.maxX, bottom = field.maxY - disc.maxY
            #expect(abs(right - bottom) < 0.25, "right gap \(right) pt, bottom gap \(bottom) pt (field \(field), disc \(disc))")
            #expect(right > 0 && bottom > 0, "the disc is inside the field")
        }
    }

    /// Multi-line: the button stays on the last line's bottom-right while the field grows and then
    /// scrolls, never covers the text, and the first character never rewraps the field.
    @Test func multiLineKeepsTheButtonPinnedWithNoLayoutShift() async throws {
        let h = try await makeHarness()
        defer { close(h) }
        let maybeCompose = h.view.controller.demo?.compose
        try #require(maybeCompose != nil)
        let compose = maybeCompose!
        let found = Self.find(h.view)
        try #require(found != nil)
        let button = found!
        let emptyClip = compose.textView.clip.frame
        await type(h, "a")
        let oneLine = button.frame
        let oneLineClip = compose.textView.clip.frame
        let oneLineField = compose.fieldRect
        #expect(oneLineClip.width == emptyClip.width, "the first character keeps the text width (no rewrap)")
        #expect(oneLineField.contains(CGPoint(x: oneLine.midX, y: oneLine.midY)))
        for i in 0..<30 {
            await type(h, "\nline \(i) of a long message that keeps going")
            let f = compose.fieldRect, b = button.frame, clip = compose.textView.clip.frame
            #expect(abs(b.maxY - oneLine.maxY) < 0.5 && abs(b.maxX - oneLine.maxX) < 0.5, "pinned bottom-right at \(i): \(b) vs \(oneLine)")
            #expect(b.maxY <= f.maxY + 0.5 && b.maxX <= f.maxX + 0.5, "inside the field at \(i)")
            #expect(clip.maxX <= b.minX + 0.5, "the text never runs under the button at \(i): clip \(clip) button \(b)")
        }
        let fieldHeight = compose.fieldRect.height
        #expect(fieldHeight <= ComposeView.maxHeight + 1, "the field stops at its max height, then scrolls")
        let finalShown = Self.shown(button)
        #expect(finalShown)
    }
}
