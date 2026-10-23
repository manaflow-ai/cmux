import AppKit
import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// Chief Home after its conversations list toggles (the transcript's width jumps) and after a
/// turn that ended on its tool calls: every row shows once, and no cell stays on screen that the
/// transcript no longer lays out (dogfood 2026-10-18: the same ask, receipt, tool rows and reply
/// drawn again and again down the transcript, only the newest copy real).
@MainActor @Suite(.serialized) struct ChiefSidebarToggleTests {
    typealias Geometry = ChiefTranscriptGeometryTests
    typealias R = ChiefRowsTests

    /// Each live row key once, rows and layout at the transcript's width, every visible cell
    /// where the layout puts it, and no shown cell outside the list's visible cells.
    static func problems(_ demo: MessagesWindowView) -> [String] {
        var out: [String] = []
        let w = demo.bounds.width
        if demo.layout.width != w { out.append("layout width \(demo.layout.width) != \(w)") }
        var seen: [String: Int] = [:]
        for (i, r) in demo.model.rows.enumerated() where !r.ghost {
            if r.spec.width != w { out.append("row \(i) \(r.spec.key) width \(r.spec.width) != \(w)") }
            if let j = seen[r.spec.key] { out.append("key \(r.spec.key) at rows \(j) and \(i)") }
            seen[r.spec.key] = i
        }
        for cell in demo.collection.visibleCells {
            guard let ip = demo.collection.indexPath(for: cell) else { continue }
            let want = demo.layout.frame(for: ip.item)
            if abs(cell.frame.minY - want.minY) > 0.5 || abs(cell.frame.width - want.width) > 0.5 {
                out.append("cell \(ip.item) at \(cell.frame) != \(want)")
            }
        }
        if let list = demo.collection as? RowRecycler { out += orphans(list) }
        return out
    }

    /// Cells on screen that the list does not track (nothing hides or reuses them again).
    static func orphans(_ list: RowRecycler) -> [String] {
        let shown = Set(list.visibleCells.map { ObjectIdentifier($0) })
        return list.subviews.compactMap { v in
            guard let cell = v as? RowCell, !cell.isHidden, !shown.contains(ObjectIdentifier(cell)) else { return nil }
            return "orphan cell \(cell.spec?.key ?? "-") at \(cell.frame)"
        }
    }

    /// Chief items: per turn my ask, `calls` tool calls (folded into the first) and a reply.
    static func chiefItems(turns: Int, calls: Int) -> [TranscriptItem] {
        var items: [TranscriptItem] = []
        var seq = 0
        for t in 0..<turns {
            seq += 1; items.append(R.item(Seq(seq), [.text("Ask \(seq): find the repo please")], by: R.me))
            for c in 0..<calls { seq += 1; items.append(R.item(Seq(seq), [R.work("w\(seq)", "Search the web \(t).\(c)", .done)])) }
            seq += 1; items.append(R.item(Seq(seq), [.text("Reply \(seq): found it, here is what the repo holds and where it lives.")]))
        }
        return items
    }

    /// A pane over `items` through the projection's mapping (tool runs folded, as Home shows them).
    static func pane(_ items: [TranscriptItem], width: CGFloat = 900) -> ChatController {
        ChiefRows.registerProviders()
        let host = HostView(frame: CGRect(x: 0, y: 0, width: width, height: 700))
        let controller = ChatController(host: host, wake: Geometry.NoWake())
        var core = ProjectionCore(me: R.me)
        let summary = ConversationSummary(id: R.id, title: "Chief", participants: R.summary.participants,
                                          lastSeq: items.last?.seq ?? 0, createdAt: R.base, updatedAt: R.base)
        let (conv, w) = core.install(R.id, items: items, summary: summary)
        controller.install(conv, windowStart: w.start, total: w.total)
        host.layoutSubtreeIfNeeded()
        return controller
    }

    /// The list hides and shows: the transcript's width jumps, then a message lands.
    @Test(arguments: [[CGFloat(1220)], [1220, 900], [1220, 900, 1220]])
    func aMessageAfterTheListTogglesLaysOutWithTheOthers(widths: [CGFloat]) {
        let controller = Geometry.pane(count: 30, size: CGSize(width: 900, height: 700))
        guard let demo = controller.demo else { Issue.record("no demo"); return }
        for w in widths {
            controller.host.setFrameSize(CGSize(width: w, height: 700))
            controller.host.layoutSubtreeIfNeeded()
        }
        #expect(Self.problems(demo) == [], "after the toggle")
        Geometry.receive(controller, 1)
        controller.host.layoutSubtreeIfNeeded()
        #expect(Self.problems(demo) == [], "after the message")
    }

    /// A turn stopped (or left waiting) on its tool calls: the message above my next ask is a
    /// folded call that shows no row. My ask, its receipt and the reply each show once, also
    /// after the list toggles.
    @Test func anAskAfterATurnThatEndedOnToolsShowsEachRowOnce() {
        var items = Self.chiefItems(turns: 6, calls: 2)
        var seq = Int(items.last?.seq ?? 0)
        seq += 1; items.append(R.item(Seq(seq), [.text("Open my cloud desktop")], by: R.me))
        seq += 1; items.append(R.item(Seq(seq), [R.work("s1", "cmux vm ls", .done)]))
        seq += 1; items.append(R.item(Seq(seq), [R.work("s2", "cmux vm open vm-1:desktop", .done)]))
        let controller = Self.pane(items)
        guard let demo = controller.demo, let store = controller.store else { Issue.record("no demo"); return }
        controller.dispatch(.setDraft("find teamleaderleo"))
        controller.dispatch(.send)
        guard let mine = store.state.conversation.messages.last?.id else { Issue.record("no send"); return }
        controller.dispatch(.status(mine, .read(at: Instant.format(HomeHarnessTests.date(1)))))
        // The receipt that moved to my ask has faded (the engine's wake drops finished ghosts).
        demo.model.dropGhosts(before: 1e9)
        let reply = R.item(Seq(seq + 2), [.text("Found teamleaderleo.")])
        controller.dispatch(.receive(R.message(reply, in: items + [reply])))
        controller.host.layoutSubtreeIfNeeded()
        #expect(Self.problems(demo) == [], "after the reply")
        for w: CGFloat in [1220, 900] {
            controller.host.setFrameSize(CGSize(width: w, height: 700))
            controller.host.layoutSubtreeIfNeeded()
        }
        #expect(Self.problems(demo) == [], "after the list toggled")
    }

    /// Two rows with one key in a pass (any slip in a row derivation): each gets a cell, and a
    /// later pass leaves no cell on screen that the list stopped tracking.
    @Test func rowsThatShareAKeyLeaveNoCellOnScreen() {
        let controller = Geometry.pane(count: 6, size: CGSize(width: 600, height: 700))
        guard let demo = controller.demo, let list = demo.collection as? RowRecycler,
              let last = demo.model.rows.last?.spec else { Issue.record("no list"); return }
        let specs = demo.model.rows.map(\.spec)
        demo.model.set(specs + [last], at: 0, ghosts: false)
        _ = demo.layout.rebaseIfNeeded(force: true)
        demo.layout.invalidateLayout()
        list.reloadData()
        list.setNeedsLayout(); list.layoutIfNeeded()
        #expect(list.visibleCells.count == demo.model.count)
        #expect(Self.orphans(list) == [])
        demo.model.set(specs, at: 0, ghosts: false)
        _ = demo.layout.rebaseIfNeeded(force: true)
        demo.layout.invalidateLayout()
        list.reloadData()
        list.setNeedsLayout(); list.layoutIfNeeded()
        #expect(Self.orphans(list) == [])
    }
}
