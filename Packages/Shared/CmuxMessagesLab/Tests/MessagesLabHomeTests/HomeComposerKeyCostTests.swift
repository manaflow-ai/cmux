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
