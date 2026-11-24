import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// A key in the Home composer does only the key's work (perf-lead.md issue 5, key to frame < 10 ms):
/// with a reply or thread view open, a key derives none of its rows again (every key ran
/// `RowBuilder.rows` over the whole thread), and the field's line count follows the typed
/// characters, not the draft (each key laid the whole draft out again in `ComposeView.lines`)
/// while it stays the count a full layout gives. The real view over a real `HomeStore` on the mock
/// owner, in an offscreen window; keys go in through the field's `insertText` (the delegate path a
/// key takes). Bench: scripts/cmux-next/typing-frame-bench.py (home, light and STRESS).
@MainActor @Suite(.serialized) struct HomeComposerKeyCostTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    static let conversation = ConversationID("conv_chief")

    private func until(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<20_000 where !condition() { await Task.yield() }
    }

    @MainActor private struct Rig {
        let store: HomeStore
        let window: NSWindow
        let view: MessagesLabHomeView
        var controller: ChatController { view.controller }
        var field: FieldTextView { controller.demo!.compose.textView.view }
        func frame() {
            view.projection.refresh()
            window.contentView?.layoutSubtreeIfNeeded()
            controller.host.layoutSubtreeIfNeeded()
            CATransaction.flush()
        }
        func type(_ text: String) {
            for c in text {
                field.insertText(String(c), replacementRange: field.selectedRange())
                window.contentView?.layoutSubtreeIfNeeded()
                CATransaction.flush()
            }
        }
        func close() { view.stop(); window.close(); store.stop() }
    }

    private func rig() async throws -> Rig {
        let options = MockHomeSource.Options(chiefHistory: 12, latency: .zero, replyDelay: .seconds(3600))
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
        view.layoutSubtreeIfNeeded()
        let r = Rig(store: store, window: window, view: view)
        r.frame()
        return r
    }

    @Test func aKeyWithAReplyViewOpenDerivesNoThreadRow() async throws {
        let r = try await rig()
        defer { r.close() }
        try #require(r.view.debugReplyNewest(mine: false) != nil, "Reply… opened no view")
        r.frame()
        r.window.makeFirstResponder(r.field)
        let demo = try #require(r.controller.demo)
        let before = demo.threadRowPasses
        r.type("one line that stays one line")
        #expect(demo.threadRowPasses == before,
                "\(demo.threadRowPasses - before) thread row passes for 28 keys with the reply view open (want 0)")
        #expect(r.controller.store?.state.ui.openThread != nil, "the reply view stays open while typing")
    }

    /// The median time of one key typed at the end of the field (the field's `insertText`, the
    /// layout and the commit a key's frame does), one key per character of `text`.
    private func medianKey(_ r: Rig, typing text: String) -> Duration {
        let clock = ContinuousClock()
        var times: [Duration] = []
        for c in text {
            let start = clock.now
            r.field.insertText(String(c), replacementRange: r.field.selectedRange())
            r.window.contentView?.layoutSubtreeIfNeeded()
            // The key's drawing too: the field's text is drawn on the display pass, not by the layout.
            r.window.displayIfNeeded()
            CATransaction.flush()
            times.append(clock.now - start)
        }
        return times.sorted()[times.count / 2]
    }

    /// The field's text is the text storage's (a bridged NSString): comparing the draft with it, or
    /// with the line memo's last draft, through Swift's String (grapheme by grapheme, normalized)
    /// cost every key a walk of the whole draft (typing-frame-bench.py home --prefill 3000:
    /// 14 to 21 ms per key in the composer's own work, Lawrence 2026-11-19 "still a bit laggy").
    /// The long part of the draft here is earlier paragraphs, which TextKit does not lay out
    /// again for a key at the end, so what is left is the composer's own per-key work.
    @Test func aKeysComposerWorkDoesNotGrowWithTheDraft() async throws {
        let r = try await rig()
        defer { r.close() }
        r.window.makeFirstResponder(r.field)
        let words = "the chief reads your note and starts on the work "
        r.field.insertText(String(repeating: "a short draft ", count: 14), replacementRange: r.field.selectedRange())
        r.frame()
        let short = medianKey(r, typing: words)
        // Earlier paragraphs, about 10,000 characters, before the typed one; the caret back at the end.
        let paragraphs = String(repeating: "the quick brown fox jumps over the lazy dog, one line of a long draft\n", count: 145)
        r.field.insertText(paragraphs, replacementRange: NSRange(location: 0, length: 0))
        r.field.setSelectedRange(NSRange(location: (r.field.string as NSString).length, length: 0))
        r.frame()
        let long = medianKey(r, typing: words)
        #expect((r.field.string as NSString).length > 10_000)
        #expect(long < short * 3,
                "a key at a 10,000 character draft takes \(long), at a 200 character draft \(short) (want under 3x)")
    }

    /// One long paragraph, the shape of a long prompt typed or pasted as one block: TextKit 2 lays out
    /// and draws a paragraph as one piece, so each key at its end laid out, measured the caret in and
    /// drew all of it again (typing-frame-bench.py home --prefill 3000, one paragraph: the key's own
    /// work 2.9 ms empty, 7.5 to 10.3 ms at 3000 characters on cmux21, Lawrence 2026-11-20 "typing
    /// still lags").
    @Test func aKeyAtTheEndOfOneLongParagraphCostsWhatAKeyInAShortOneDoes() async throws {
        let r = try await rig()
        defer { r.close() }
        r.window.makeFirstResponder(r.field)
        let sentence = "the chief reads your note and starts on the work in a new workspace "
        let words = "and then it reports back with what it found "
        r.field.insertText(String(repeating: sentence, count: 3), replacementRange: r.field.selectedRange())
        r.frame()
        let short = medianKey(r, typing: words)
        r.field.insertText(String(repeating: sentence, count: 120), replacementRange: NSRange(location: 0, length: 0))
        r.field.setSelectedRange(NSRange(location: (r.field.string as NSString).length, length: 0))
        r.frame()
        let long = medianKey(r, typing: words)
        #expect(!r.field.string.contains("\n") && (r.field.string as NSString).length > 8_000)
        #expect(long < short * 3,
                "a key at the end of an 8,000 character paragraph takes \(long), in a 250 character one \(short) (want under 3x)")
    }

    @Test func theFieldsLineCountFollowsTypingAndMatchesAFullLayout() async throws {
        let r = try await rig()
        defer { r.close() }
        r.window.makeFirstResponder(r.field)
        let compose = try #require(r.controller.demo?.compose)
        let width = r.view.bounds.width
        let words = "the quick brown fox jumps over the lazy dog while a supercalifragilisticexpialidociouslylongword wraps; "
        var text = ""
        for c in String(repeating: words, count: 6) {
            text.append(c)
            let typed = compose.lines(text, windowWidth: width)
            let field = ComposeView.fieldWidth(width) - 24 - compose.trailingReserve
            let full = TextLayout.make(text, runs: [], maxWidth: field, font: ComposeView.font).lines.count
            if typed != full {
                Issue.record("\(typed) lines while typing, \(full) laid out whole, at \(text.count) characters")
                return
            }
        }
        // An edit that is not an append (a deletion, a paste in the middle) lays out the whole draft.
        let cut = String(text.dropLast(40))
        let field = ComposeView.fieldWidth(width) - 24 - compose.trailingReserve
        #expect(compose.lines(cut, windowWidth: width) == TextLayout.make(cut, runs: [], maxWidth: field, font: ComposeView.font).lines.count)
    }
}
