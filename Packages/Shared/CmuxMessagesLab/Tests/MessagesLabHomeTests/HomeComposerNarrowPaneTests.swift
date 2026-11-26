import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// A Home chat in a narrow pane (a split's third column, about 150 pt wide) broke the draft after
/// every character: the field kept Messages' fixed "+" and emoji buttons, so the text had no width
/// left ("hello? (2)" stood one character per line, fleet capture 2026-11-20). The real view over a
/// real `HomeStore` on the mock owner, in an offscreen window at each pane width; the draft goes in
/// through the field's `insertText` (the path a key takes). What is read is what a person sees: the
/// draft's line count in the field, the field's height, and which glass buttons show and where.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct HomeComposerNarrowPaneTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    static let conversation = ConversationID("conv_chief")
    static let draft = "hello? (2)"

    struct Harness {
        let store: HomeStore
        let window: NSWindow
        let view: MessagesLabHomeView
        let field: NSTextView
        let compose: ComposeView
        let chrome: FieldChrome
    }

    private func until(_ condition: @escaping @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else { Issue.record("the condition never held"); return }
            await Task.yield()
        }
    }

    private func makeHarness(width: CGFloat) async throws -> Harness {
        // The field takes its height at once: the heights are what these tests read, not the spring.
        MessagesLabHomeView.reduceMotionOverride = true
        let options = MockHomeSource.Options(chiefHistory: 20, latency: .zero, replyDelay: .seconds(3600))
        let store = HomeStore(source: MockHomeSource(options: options))
        store.start()
        await until { store.me != nil && store.isOnline }
        await store.open(Self.conversation)
        await until { !store.transcript(for: Self.conversation).isEmpty }
        let me = try #require(store.me?.id)
        let frame = NSRect(x: 0, y: 0, width: width, height: 600)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let view = MessagesLabHomeView(store: store, conversation: Self.conversation, me: me, wake: NoWake())
        view.frame = frame
        window.contentView = view
        view.projection.refresh()
        view.layoutSubtreeIfNeeded()
        let maybeCompose = view.controller.demo?.compose
        try #require(maybeCompose != nil)
        let compose = maybeCompose!
        return Harness(store: store, window: window, view: view, field: compose.textView.view, compose: compose,
                       chrome: view.controller.host.fieldChrome)
    }

    private func close(_ h: Harness) {
        h.view.stop(); h.window.close(); h.store.stop()
        MessagesLabHomeView.reduceMotionOverride = nil
    }

    private func settle(_ h: Harness) async {
        for _ in 0..<8 { await Task.yield() }
        h.window.contentView?.layoutSubtreeIfNeeded()
    }

    /// The draft's laid-out lines in the field's text view.
    private func lines(_ field: NSTextView) -> Int {
        guard let lm = field.layoutManager, let tc = field.textContainer else { return 0 }
        lm.ensureLayout(for: tc)
        var count = 0, index = 0
        let glyphs = lm.numberOfGlyphs
        while index < glyphs {
            var range = NSRange(location: 0, length: 0)
            lm.lineFragmentRect(forGlyphAt: index, effectiveRange: &range)
            count += 1
            index = NSMaxRange(range)
        }
        return count
    }

    /// The pane widths of a narrow column: the drag capture's third column (148 pt), a split's
    /// narrow side, and the width where Messages' full bar still leaves a short draft its line.
    @Test(arguments: [148.0, 180.0, 220.0, 260.0])
    func shortDraftStaysOnOneLine(width: Double) async throws {
        let h = try await makeHarness(width: CGFloat(width))
        defer { close(h) }
        let empty = h.compose.fieldHeight
        h.field.insertText(Self.draft, replacementRange: h.field.selectedRange())
        await settle(h)
        #expect(lines(h.field) == 1, "\"\(Self.draft)\" at a \(width) pt pane takes \(lines(h.field)) lines")
        #expect(h.compose.fieldHeight == empty, "the field grew from \(empty) to \(h.compose.fieldHeight) pt at \(width) pt")
        // The text column holds at least a short word and its neighbours, never a character or two.
        #expect(h.compose.textWidth >= 72, "the text column is \(h.compose.textWidth) pt at \(width) pt")
    }

    /// No glass button covers the field, and a shown button is inside the pane.
    @Test(arguments: [148.0, 180.0, 220.0, 260.0, 700.0])
    func buttonsNeverCoverTheField(width: Double) async throws {
        let h = try await makeHarness(width: CGFloat(width))
        defer { close(h) }
        let field = h.chrome.field.frame
        for (name, glass) in [("+", h.chrome.plusGlass), ("emoji", h.chrome.emojiGlass)] where !glass.isHidden {
            #expect(!glass.frame.intersects(field), "the \(name) button covers the field at \(width) pt")
            #expect(glass.frame.minX >= 0 && glass.frame.maxX <= CGFloat(width), "the \(name) button is outside the pane at \(width) pt")
        }
        #expect(field.minX >= 0 && field.maxX <= CGFloat(width), "the field is outside the pane at \(width) pt")
    }

    /// A pane as wide as a normal window keeps Messages' bar: both buttons show.
    @Test func wideHomeKeepsBothButtons() async throws {
        let h = try await makeHarness(width: 700)
        defer { close(h) }
        #expect(!h.chrome.plusGlass.isHidden)
        #expect(!h.chrome.emojiGlass.isHidden)
        // Messages' field starts 9.5 pt right of the "+" button (10.5 pt in, 31 pt wide).
        #expect(h.chrome.field.frame.minX == 51)
    }
}
