import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// Reply to Selection (Lawrence 2026-10-20: "If I highlight text in the message UI, I need to be
/// able to right-click it and respond only to that text, not to the full entire message";
/// plans/cmux-next/reply-to-selection-DESIGN.md). The real view (`MessagesLabHomeView`) over a real
/// `HomeStore` on the mock owner, in an offscreen window: a word of the Chief's message is selected,
/// the right-click menu offers Reply to Selection, the reply goes out quoting only that word, the
/// sent bubble shows the quote, and a click on it flashes the quoted words in the original.
@MainActor @Suite(.serialized) struct HomeReplyToSelectionTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    static let conversation = ConversationID("conv_chief")
    static let replyToSelection = "Reply to Selection"

    private func until(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<20_000 where !condition() { await Task.yield() }
    }

    @MainActor private struct Rig {
        let store: HomeStore
        let window: NSWindow
        let view: MessagesLabHomeView
        let me: ParticipantID
        func frame() {
            view.projection.refresh()
            window.contentView?.layoutSubtreeIfNeeded()
            view.controller.host.layoutSubtreeIfNeeded()
            CATransaction.flush()
        }
        func close() { view.stop(); window.close(); store.stop() }
    }

    private func rig() async throws -> Rig {
        let options = MockHomeSource.Options(chiefHistory: 6, latency: .zero, replyDelay: .seconds(3600))
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
        let r = Rig(store: store, window: window, view: view, me: me)
        r.frame()
        return r
    }

    /// The shown bubble whose text starts with `prefix` (the thread view's when one is open), on a coarse grid.
    private func bubble(_ r: Rig, prefix: String) -> MessagesWindowView.Hit? {
        guard let demo = r.view.controller.demo else { return nil }
        let b = r.view.controller.host.bounds
        for y in stride(from: b.maxY, to: b.minY, by: -6) {
            for x in stride(from: b.minX, to: b.maxX, by: 12) {
                if let hit = demo.hit(CGPoint(x: x, y: y)), case let .text(shown, _) = hit.row.part, shown.hasPrefix(prefix) { return hit }
            }
        }
        return nil
    }

    private func menuLabels(_ menu: NSMenu) -> [String] { menu.items.compactMap { ($0 as? MenuAction)?.label } }

    private func choose(_ label: String, in menu: NSMenu) throws {
        let item = try #require(menu.items.first { ($0 as? MenuAction)?.label == label }, "no \(label) in \(menuLabels(menu))")
        NSApp.sendAction(try #require(item.action), to: item.target, from: item)
    }

    @Test func noSelectionKeepsTheMenuAsItWas() async throws {
        let r = try await rig()
        defer { r.close() }
        let row = try #require(r.view.controller.demo?.lastTextRow(mine: false))
        let menu = try #require(r.view.controller.menu(at: CGPoint(x: row.body.midX, y: row.body.midY)))
        r.view.controller.menuHighlight?.discard()
        #expect(!menuLabels(menu).contains(Self.replyToSelection))
        #expect(menuLabels(menu).contains(Strings.menuReplyEllipsis))
    }

    @Test func aSelectionRepliesWithOnlyTheSelectedWordsQuoted() async throws {
        let r = try await rig()
        defer { r.close() }
        let controller = r.view.controller
        let row = try #require(controller.demo?.lastTextRow(mine: false))
        guard case let .text(original, _) = row.row.part else { Issue.record("not a text row"); return }
        // A word of the Chief's message (double-click selects a word).
        #expect(controller.selection.selectWord(at: CGPoint(x: row.body.minX + 30, y: row.body.minY + 12)))
        controller.selection.refresh()
        let selected = controller.selection.selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        try #require(!selected.isEmpty && selected.count < original.count, "selected \(selected)")

        // Right-click on it: Reply to Selection, before Reply…
        let menu = try #require(controller.menu(at: CGPoint(x: row.body.minX + 30, y: row.body.minY + 12)))
        controller.menuHighlight?.discard(); controller.menuHighlight = nil
        let labels = menuLabels(menu)
        let at = try #require(labels.firstIndex(of: Self.replyToSelection), "menu: \(labels)")
        let reply = try #require(labels.firstIndex(of: Strings.menuReplyEllipsis))
        #expect(at < reply)
        try choose(Self.replyToSelection, in: menu)
        r.frame()
        #expect(controller.store?.state.ui.openThread != nil, "Reply to Selection opens the thread composer as Reply… does")

        // The reply goes out with only that word quoted.
        let seqBefore = r.store.summary(Self.conversation)?.lastSeq ?? 0
        controller.dispatch(.setDraft("Why that one?"))
        #expect(r.view.projection.send() == nil, "the send was refused")
        await until { (r.store.summary(Self.conversation)?.lastSeq ?? 0) > seqBefore }
        r.frame()
        let sent = try #require(r.store.transcript(for: Self.conversation).last { $0.author == r.me })
        let text = sent.parts.compactMap { if case let .text(t, _) = $0 { t } else { nil } }.joined()
        #expect(text == "> \(selected)\n\nWhy that one?", "sent: \(text)")
        #expect(sent.replyTo != nil, "the reply answers the message")

        // The sent bubble shows the quote, quietly, above the reply.
        let shown = controller.store?.state.conversation.messages.last { $0.senderId == r.me.rawValue }
        guard case let .text(bubble, runs)? = shown?.parts.first else { Issue.record("no sent bubble"); return }
        #expect(bubble == "\u{201C}\(selected)\u{201D}\nWhy that one?", "bubble: \(bubble)")
        #expect(runs.contains { $0.start == 0 && $0.style?.contains("quote") == true })
    }

    @Test func clickingTheQuoteFlashesTheQuotedWordsInTheOriginal() async throws {
        let r = try await rig()
        defer { r.close() }
        let controller = r.view.controller
        let row = try #require(controller.demo?.lastTextRow(mine: false))
        #expect(controller.selection.selectWord(at: CGPoint(x: row.body.minX + 30, y: row.body.minY + 12)))
        let menu = try #require(controller.menu(at: CGPoint(x: row.body.minX + 30, y: row.body.minY + 12)))
        controller.menuHighlight?.discard(); controller.menuHighlight = nil
        try choose(Self.replyToSelection, in: menu)
        let seqBefore = r.store.summary(Self.conversation)?.lastSeq ?? 0
        controller.dispatch(.setDraft("This part"))
        #expect(r.view.projection.send() == nil)
        await until { (r.store.summary(Self.conversation)?.lastSeq ?? 0) > seqBefore }
        r.frame()

        // My reply in the open thread view: a click on its quote line.
        let mine = try #require(bubble(r, prefix: "\u{201C}"), "no quoted reply shown")
        controller.clicked(CGPoint(x: mine.body.minX + 14, y: mine.body.minY + 10))
        r.frame()
        var flashes: [CALayer] = []
        func walk(_ l: CALayer) { if l.name == "cmux.replyQuoteFlash" { flashes.append(l) }; l.sublayers?.forEach(walk) }
        if let root = controller.host.layer { walk(root) }
        #expect(!flashes.isEmpty, "a click on the quote flashes the quoted words")
    }
}
