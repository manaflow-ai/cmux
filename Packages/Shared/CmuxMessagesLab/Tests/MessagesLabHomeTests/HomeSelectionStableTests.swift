import AppKit
import CmuxHomeCore
import Testing
@testable import MessagesLabHome

/// A text selection in the Home transcript stays on its text while other rows
/// change (Lawrence 2026-10-19: "when there's a new message that comes in,
/// there is a layout shift for the highlight thing and it looks a little janky
/// and disjoint"). Rows move with springs on their own cells (a new message
/// pushes the older rows up); a highlight drawn outside the row lands at the
/// row's end place at once while the text springs there. These tests drive a
/// real `ChatController` over a loaded conversation in an offscreen window and
/// check that the drawn highlight is carried by the selected row's own layers,
/// sits on the same glyph rects before and after the change, and that the
/// selected text survives inserts, streaming growth and the stream's end.
@MainActor @Suite(.serialized) struct HomeSelectionStableTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    struct Pane {
        let window: NSWindow
        let controller: ChatController
        var demo: MessagesWindowView { controller.demo! }
    }

    static let me = ParticipantID("user_me")
    static let them = ParticipantID("agent_chief")

    /// `windowStart`: older messages exist above the loaded window (a page can load there).
    private func pane(windowStart: Int? = nil) -> Pane {
        let people = [CmuxHomeCore.Participant(id: Self.me, kind: .human, displayName: "Me"),
                      CmuxHomeCore.Participant(id: Self.them, kind: .agent, displayName: "Chief", agentClass: .chief)]
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let items = (1...6).map { i in
            TranscriptItem(key: IdempotencyKey("k\(i)"), seq: Seq(i), author: i % 2 == 0 ? Self.me : Self.them,
                           parts: [.text("Message number \(i) with a few words")], createdAt: base.addingTimeInterval(Double(i)),
                           delivery: .committed, messageID: MessageID("msg_\(i)"))
        }
        let summary = ConversationSummary(id: ConversationID("conv_sel"), title: "Chief", participants: people, lastSeq: 6,
                                          createdAt: base, updatedAt: base, readCursors: [:], readCursorTimes: [:])
        var core = ProjectionCore(me: Self.me)
        core.replies = .streaming // the older stream bubble (HomeReplyDisplay)
        let (conv, w) = core.install(ConversationID("conv_sel"), items: items, summary: summary)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let controller = ChatController(host: HostView(frame: NSRect(x: 0, y: 0, width: 600, height: 700)), wake: NoWake())
        window.contentView = controller.host
        controller.install(conv, windowStart: windowStart ?? w.start, total: windowStart.map { $0 + w.total } ?? w.total)
        controller.host.layoutSubtreeIfNeeded()
        return Pane(window: window, controller: controller)
    }

    private func settle(_ p: Pane) {
        p.controller.host.layoutSubtreeIfNeeded()
        p.demo.layoutIfNeeded()
        p.demo.collection.layoutIfNeeded()
        p.controller.selection.refresh()
    }

    private func message(_ id: String, _ text: String) -> MessagesLabHome.Message {
        MessagesLabHome.Message(id: id, senderId: Self.them.rawValue, sentAt: Instant.format(Date(timeIntervalSince1970: 1_800_000_100)),
                                parts: [.text(text, runs: [])], replyTo: nil, status: nil, edits: nil, retractedAt: nil, reactions: [])
    }

    /// The cell that shows row `key`.
    private func cell(_ p: Pane, key: String) -> RowCell? {
        p.demo.collection.visibleCells.compactMap { $0 as? RowCell }.first { !$0.isHidden && $0.key == key }
    }

    /// Every drawn selection-highlight layer under the pane: a shape layer with a path and the
    /// highlight's screen blend.
    private func highlightLayers(_ p: Pane) -> [CAShapeLayer] {
        var out: [CAShapeLayer] = []
        func walk(_ l: CALayer) {
            if let s = l as? CAShapeLayer, s.path != nil, !s.isHidden, s.compositingFilter as? String == "screenBlendMode" { out.append(s) }
            l.sublayers?.forEach(walk)
        }
        // Every view's layer tree under the pane (the rows and any overlay are hosted layers of subviews).
        var seen = Set<ObjectIdentifier>()
        func views(_ v: NSView) {
            if let l = v.layer, seen.insert(ObjectIdentifier(l)).inserted { walk(l) }
            v.subviews.forEach(views)
        }
        views(p.controller.host)
        var unique = Set<ObjectIdentifier>()
        return out.filter { unique.insert(ObjectIdentifier($0)).inserted }
    }

    private func isDescendant(_ l: CALayer, of ancestor: CALayer) -> Bool {
        var s: CALayer? = l
        while let c = s { if c === ancestor { return true }; s = c.superlayer }
        return false
    }

    /// The highlight drawn for row `key`, in its cell's layer coordinates, and whether every
    /// highlight layer that draws it is inside that cell (so the row's own motion moves it).
    private func drawnHighlight(_ p: Pane, key: String) throws -> (rects: CGRect, carriedByRow: Bool) {
        let c = try #require(cell(p, key: key))
        let layers = highlightLayers(p)
        try #require(!layers.isEmpty, "no highlight drawn")
        var union = CGRect.null
        var carried = true
        for l in layers {
            let box = l.path!.boundingBoxOfPath
            union = union.union(l.convert(box, to: c.layer))
            if !isDescendant(l, of: c.layer) { carried = false }
        }
        return (union, carried)
    }

    private func selectWord(_ p: Pane, mine: Bool = false) throws -> String {
        let row = try #require(p.demo.lastTextRow(mine: mine))
        #expect(p.controller.selection.selectWord(at: CGPoint(x: row.body.minX + 30, y: row.body.midY)))
        settle(p)
        return row.key
    }

    // MARK: A new message below

    @Test func aNewMessageKeepsTheSelectionOnItsText() throws {
        let p = pane()
        let key = try selectWord(p)
        let text = p.controller.selection.selectedText
        #expect(!text.isEmpty)
        let before = try drawnHighlight(p, key: key)
        p.controller.dispatch(.receive(message("msg_new", "A new reply arrives below the selection")))
        settle(p)
        #expect(p.controller.selection.selectedText == text)
        let after = try drawnHighlight(p, key: key)
        // The row springs up to its new place: the highlight must ride in the row, not land there first.
        #expect(after.carriedByRow, "the highlight is drawn outside its row: it jumps while the row springs")
        #expect(abs(after.rects.minX - before.rects.minX) < 0.5 && abs(after.rects.minY - before.rects.minY) < 0.5)
        #expect(abs(after.rects.width - before.rects.width) < 0.5 && abs(after.rects.height - before.rects.height) < 0.5)
    }

    // MARK: An older page loads above

    @Test func anOlderPageLoadingAboveKeepsTheSelectionInPlace() throws {
        let p = pane(windowStart: 3)
        let key = try selectWord(p)
        let text = p.controller.selection.selectedText
        let before = try drawnHighlight(p, key: key)
        let top = try #require(cell(p, key: key)).convert(CGRect.zero, to: p.demo).minY
        let rows = p.demo.model.count
        let older = (0..<3).map { i in
            MessagesLabHome.Message(id: "msg_old_\(i)", senderId: Self.them.rawValue,
                                    sentAt: Instant.format(Date(timeIntervalSince1970: 1_799_999_000 + Double(i))),
                                    parts: [.text("An older message \(i) from the page above", runs: [])], replyTo: nil, status: nil,
                                    edits: nil, retractedAt: nil, reactions: [])
        }
        p.controller.dispatch(.prependPage(older))
        settle(p)
        try #require(p.demo.model.count > rows, "the page did not load")
        #expect(p.controller.selection.selectedText == text)
        let after = try drawnHighlight(p, key: key)
        #expect(after.carriedByRow)
        #expect(abs(after.rects.minY - before.rects.minY) < 0.5 && abs(after.rects.minX - before.rects.minX) < 0.5)
        // Rows land above: the selected row keeps its place on screen.
        let nowTop = try #require(cell(p, key: key)).convert(CGRect.zero, to: p.demo).minY
        #expect(abs(nowTop - top) < 0.5, "the selected row moved \(nowTop - top) pt when a page loaded above")
    }

    // MARK: A streaming reply grows and ends

    @Test func aStreamingReplyGrowingBelowKeepsTheSelection() throws {
        let p = pane()
        let key = try selectWord(p)
        let text = p.controller.selection.selectedText
        let before = try drawnHighlight(p, key: key)
        let sid: StreamID = "turn_sel"
        p.controller.dispatch(.streamBegin(sid, sender: Self.them.rawValue))
        p.controller.dispatch(.streamSet(sid, text: "Working on it"))
        settle(p)
        for chunk in [" and it grows", " onto a second line of text in the bubble", " and then a third line as the reply streams on."] {
            p.controller.dispatch(.streamAppend(sid, text: chunk))
            settle(p)
            #expect(p.controller.selection.selectedText == text)
            let now = try drawnHighlight(p, key: key)
            #expect(now.carriedByRow)
            #expect(abs(now.rects.minY - before.rects.minY) < 0.5 && abs(now.rects.minX - before.rects.minX) < 0.5)
        }
    }

    @Test func aSelectionInTheStreamingReplySurvivesItsEnd() throws {
        let p = pane()
        let sid: StreamID = "turn_sel_end"
        let full = "Streaming reply with several words in it"
        p.controller.dispatch(.streamBegin(sid, sender: Self.them.rawValue))
        p.controller.dispatch(.streamSet(sid, text: full))
        settle(p)
        let key = try selectWord(p)
        let text = p.controller.selection.selectedText
        #expect(!text.isEmpty)
        // The final message takes the stream's rows in place (renameStreamRows): the selection goes with them.
        p.controller.dispatch(.streamEnd(sid, replacedBy: message("msg_final", full)))
        settle(p)
        #expect(p.controller.selection.selectedText == text, "the stream's end cleared the selection")
        let newKey = try #require(p.demo.lastTextRow(mine: false)?.key)
        #expect(newKey != key)
        let after = try drawnHighlight(p, key: newKey)
        #expect(after.carriedByRow)
    }

    // MARK: Reused cells

    @Test func clearingTheSelectionLeavesNoHighlight() throws {
        let p = pane()
        _ = try selectWord(p)
        #expect(!highlightLayers(p).isEmpty)
        p.controller.selection.clear()
        settle(p)
        #expect(highlightLayers(p).isEmpty)
    }
}
