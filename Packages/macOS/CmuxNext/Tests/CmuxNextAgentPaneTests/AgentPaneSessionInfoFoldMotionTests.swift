import AppKit
import CmuxNextDesign
import CmuxNextTestSupport
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A native Session Info fold is one state transition on the settle (Leo 2026-11-07, of a reference panel's
/// folds: "it needs to follow the little bumps and whatnot for the easing", "they dont overshoot but they
/// decelerate at the end"). The section's rows reveal or clip, every section below and the panel's height move
/// on the same progress in the same frames, the chevron turns on it, and nothing is added after the motion ends.
/// An interrupted fold continues from what is on screen; with motion off the end applies in one frame.
@Suite(.serialized)
@MainActor
struct AgentPaneSessionInfoFoldMotionTests {
    /// Two foldable sections in one group: Subagents (two rows and a "View all") above Tasks (one row).
    private static func model(subagentsOpen: Bool) throws -> AgentPaneSessionInfoModel {
        let info: [String: Any] = [
            "open": true, "width": 320, "top": 28, "side": 0, "label": "Session Info",
            "sections": [
                ["id": "subagents", "group": "running", "title": "Subagents", "meta": "2 running", "open": subagentsOpen,
                 "foldable": true,
                 "rows": [["id": "a1", "title": "rail-fix", "tone": "running", "action": "subagents.open:a1"],
                          ["id": "a2", "title": "fold-sweep", "subtitle": "a second line under the title", "tone": "running",
                           "action": "subagents.open:a2"]],
                 "more": ["label": "View all", "action": "subagents.all"]],
                ["id": "tasks", "group": "running", "title": "Tasks", "meta": "1", "open": true, "foldable": true,
                 "rows": [["id": "t1", "title": "build", "tone": "running"]]],
            ],
        ]
        return try #require(AgentPaneSessionInfoModel.decode(info))
    }

    private struct Fixture {
        let store: AgentPaneSessionInfoStore
        let panel: AgentPaneSessionInfoPanel
        let content: AgentPaneSessionInfoContent
        var list: SessionInfoListView { content.listView }

        /// The top of line `id` (-1 when it is not in the list).
        func top(_ id: String) -> CGFloat { content.lines.first { $0.line.id == id }?.frame.minY ?? -1 }
        /// Section `id`'s chevron turn (-1 when its header is not in the list).
        func turn(_ id: String) -> CGFloat { content.lines.first { $0.line.id == id }?.foldTurn ?? -1 }
        var subagentRows: [SessionInfoLineView] {
            content.lines.filter { $0.line.id?.hasPrefix("row:subagents:") == true || $0.line.id == "more:subagents" }
        }
        /// The natural height of Subagents' folding lines (the travel of its fold).
        var travel: CGFloat { subagentRows.reduce(0) { $0 + $1.height(forWidth: $1.frame.width) } }
        var shownRows: CGFloat { subagentRows.reduce(0) { $0 + $1.frame.height } }
        var identities: Set<ObjectIdentifier> { Set(content.lines.map(ObjectIdentifier.init)) }
    }

    /// The panel's height read by its owner each time the list says its height changed (`store.relayout`, as
    /// AgentPaneView+SessionInfo does), so a test sees the panel's frame of that frame.
    private static func make(subagentsOpen: Bool, heights: @escaping (CGFloat) -> Void) throws -> Fixture {
        let store = AgentPaneSessionInfoStore()
        let panel = AgentPaneSessionInfoPanel(store: store)
        store.relayout = { [weak panel] in heights(panel?.fittingHeight(forWidth: 320) ?? -1) }
        panel.frame = CGRect(x: 0, y: 0, width: 320, height: 800)
        store.update(try model(subagentsOpen: subagentsOpen))
        panel.layoutSubtreeIfNeeded()
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let content = try #require(all(panel).compactMap { $0 as? AgentPaneSessionInfoContent }.first)
        let fixture = Fixture(store: store, panel: panel, content: content)
        // A one-second fold, stepped by hand: the shares are the settle curve's at each elapsed fraction.
        fixture.list.foldDuration = { _ in 1 }
        return fixture
    }

    @Test func anUnfoldMovesTheSectionsBelowAndThePanelOnOneProgress() throws {
        var panelHeights: [CGFloat] = []
        let fixture = try Self.make(subagentsOpen: false) { panelHeights.append($0) }
        let list = fixture.list
        let tasksTop = fixture.top("tasks")
        let closedHeight = list.frame.height
        #expect(fixture.subagentRows.isEmpty)

        try fixture.store.update(Self.model(subagentsOpen: true))
        // The first frame is the start state: the rows are in, at no height, and nothing below has moved.
        #expect(fixture.subagentRows.count == 3)
        #expect(fixture.subagentRows.allSatisfy { $0.frame.height == 0 })
        #expect(fixture.top("tasks") == tasksTop)
        #expect(list.frame.height == closedHeight)
        #expect(fixture.turn("subagents") == 0)
        #expect(list.foldMotion.isRunning)
        let travel = fixture.travel
        #expect(travel > 3 * SessionInfoMetrics.rowHeight - 0.5)
        let present = fixture.identities

        var elapsed = 0.0
        for dt in [1.0 / 120, 0.05, 0.1, 0.2, 0.3] {
            #expect(list.foldMotion.motionStep(dt))
            elapsed += dt
            let share = CGFloat(TimedProgress.progress(at: elapsed, curve: .settle))
            // One share moves the rows' reveal, the next section, the list, the panel and the chevron.
            #expect(abs(fixture.shownRows - travel * share) < 0.01, "rows at \(elapsed) s")
            #expect(abs(fixture.top("tasks") - (tasksTop + travel * share)) < 0.01, "Tasks at \(elapsed) s")
            #expect(abs(list.frame.height - (closedHeight + travel * share)) < 0.01, "list at \(elapsed) s")
            #expect(abs((panelHeights.last ?? -1) - list.frame.height) < 0.5, "panel at \(elapsed) s")
            #expect(abs(fixture.turn("subagents") - share) < 1e-6, "chevron at \(elapsed) s")
            #expect(fixture.identities == present, "a line came or went mid-fold at \(elapsed) s")
        }

        #expect(list.foldMotion.motionStep(1))
        #expect(fixture.top("tasks") == tasksTop + travel)
        let endHeight = list.frame.height
        // The completion frame changes nothing: no row is added, no height moves after the motion ends.
        #expect(!list.foldMotion.motionStep(1.0 / 120))
        #expect(!list.foldMotion.isRunning)
        #expect(fixture.identities == present)
        #expect(list.frame.height == endHeight)
        #expect(fixture.subagentRows.allSatisfy { $0.fullHeight == nil && $0.frame.height == $0.height(forWidth: $0.frame.width) })
        #expect(fixture.turn("subagents") == 1)
    }

    @Test func aFoldClipsItsRowsAwayAndThenTheyGo() throws {
        var panelHeights: [CGFloat] = []
        let fixture = try Self.make(subagentsOpen: true) { panelHeights.append($0) }
        let list = fixture.list
        let tasksTop = fixture.top("tasks")
        let openHeight = list.frame.height
        let travel = fixture.travel
        let rows = fixture.subagentRows
        #expect(rows.count == 3)

        try fixture.store.update(Self.model(subagentsOpen: false))
        // The model has no rows now, but they stay on screen, whole, until the fold moves them.
        #expect(fixture.subagentRows.map(ObjectIdentifier.init) == rows.map(ObjectIdentifier.init))
        #expect(abs(fixture.shownRows - travel) < 0.01)
        #expect(fixture.top("tasks") == tasksTop)
        #expect(fixture.turn("subagents") == 1)

        #expect(list.foldMotion.motionStep(0.08))
        let share = CGFloat(TimedProgress.progress(at: 0.08, curve: .settle))
        #expect(share > 0 && share < 1)
        #expect(abs(fixture.shownRows - travel * (1 - share)) < 0.01)
        #expect(abs(fixture.top("tasks") - (tasksTop - travel * share)) < 0.01)
        #expect(abs(list.frame.height - (openHeight - travel * share)) < 0.01)
        #expect(abs((panelHeights.last ?? -1) - list.frame.height) < 0.5)
        #expect(abs(fixture.turn("subagents") - (1 - share)) < 1e-6)
        // The row the section's edge crosses keeps its content in place and clips at the edge.
        let crossed = try #require(fixture.subagentRows.first { $0.fullHeight != nil })
        #expect(crossed.frame.height < (crossed.fullHeight ?? 0))
        #expect(crossed.layer?.masksToBounds == true)

        #expect(list.foldMotion.motionStep(1))
        #expect(abs(fixture.shownRows) < 0.01)
        #expect(!list.foldMotion.motionStep(1.0 / 120))
        // At the end the clipped-away lines go, and nothing else changes.
        #expect(fixture.subagentRows.isEmpty)
        #expect(fixture.content.lines.map(\.line.title) == ["Subagents", "Tasks", "build"])
        #expect(abs(list.frame.height - (openHeight - travel)) < 0.01)
        #expect(fixture.turn("subagents") == 0)
    }

    /// Folding again mid-unfold turns around from the frame on screen: no jump, no restart from an end.
    @Test func anInterruptedFoldContinuesFromWhatIsOnScreen() throws {
        let fixture = try Self.make(subagentsOpen: false) { _ in }
        let list = fixture.list
        let tasksTop = fixture.top("tasks")
        try fixture.store.update(Self.model(subagentsOpen: true))
        let travel = fixture.travel
        #expect(list.foldMotion.motionStep(0.04))
        let shown = fixture.top("tasks")
        let turn = fixture.turn("subagents")
        #expect(shown > tasksTop && shown < tasksTop + travel)

        try fixture.store.update(Self.model(subagentsOpen: false))
        // The turn's first frame is the frame that was on screen.
        #expect(abs(fixture.top("tasks") - shown) < 0.01)
        #expect(abs(fixture.turn("subagents") - turn) < 1e-6)
        #expect(fixture.subagentRows.count == 3)
        #expect(list.foldMotion.motionStep(0.05))
        let back = fixture.top("tasks")
        #expect(back < shown && back > tasksTop)
        #expect(list.foldMotion.motionStep(1))
        #expect(!list.foldMotion.motionStep(1.0 / 120))
        #expect(fixture.top("tasks") == tasksTop)
        #expect(fixture.subagentRows.isEmpty)
    }

    /// With motion off (a zero-length fold: the master switch, `ui.animations.home`, speed off or Reduce Motion
    /// all give `Motion.home` 0) the end state applies in the update's own frame and the fold's completion runs.
    @Test func withMotionOffAFoldAppliesInOneFrame() throws {
        var panelHeights: [CGFloat] = []
        let fixture = try Self.make(subagentsOpen: false) { panelHeights.append($0) }
        let list = fixture.list
        list.foldDuration = { _ in 0 }
        let tasksTop = fixture.top("tasks")
        let closedHeight = list.frame.height

        try fixture.store.update(Self.model(subagentsOpen: true))
        #expect(!list.foldMotion.isRunning)
        let travel = fixture.travel
        #expect(abs(fixture.shownRows - travel) < 0.01)
        #expect(fixture.top("tasks") == tasksTop + travel)
        #expect(abs((panelHeights.last ?? -1) - list.frame.height) < 0.5)
        #expect(fixture.turn("subagents") == 1)

        try fixture.store.update(Self.model(subagentsOpen: false))
        #expect(!list.foldMotion.isRunning)
        // The completion ran: the rows are gone, not left behind at no height.
        #expect(fixture.subagentRows.isEmpty)
        #expect(fixture.top("tasks") == tasksTop)
        #expect(list.frame.height == closedHeight)
        #expect(fixture.turn("subagents") == 0)
    }

    /// The chevron is one glyph that turns: open it points down, folded right (drawn, then read back by its ink's
    /// shape: a "v" is wide at its top, a ">" is tall at its left).
    @Test func theChevronPointsDownOpenAndRightFolded() throws {
        func ink(_ view: NSView) throws -> [(x: Int, y: Int)] {
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            var points: [(x: Int, y: Int)] = []
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { points.append((x, y)) }
            }
            return points
        }
        /// The ink's extent across, in the first and last quarter of its extent along `vertical` (rows) or columns.
        func spreads(_ points: [(x: Int, y: Int)], alongRows: Bool) -> (first: Int, last: Int) {
            let along = points.map { alongRows ? $0.y : $0.x }
            let across = { (point: (x: Int, y: Int)) in alongRows ? point.x : point.y }
            let low = along.min() ?? 0, high = along.max() ?? 0
            let quarter = max(1, (high - low) / 4)
            let first = points.filter { (alongRows ? $0.y : $0.x) <= low + quarter }.map(across)
            let last = points.filter { (alongRows ? $0.y : $0.x) >= high - quarter }.map(across)
            return ((first.max() ?? 0) - (first.min() ?? 0), (last.max() ?? 0) - (last.min() ?? 0))
        }
        let open = SessionInfoChevronView(font: Typography.body, tint: .black, unfolded: true)
        open.frame = CGRect(x: 0, y: 0, width: 32, height: 32)
        let down = try ink(open)
        #expect(down.count > 10)
        let rows = spreads(down, alongRows: true)
        #expect(rows.first > rows.last, "an open chevron's top is \(rows.first) wide and its foot \(rows.last): not a v")

        let folded = SessionInfoChevronView(font: Typography.body, tint: .black, unfolded: false)
        folded.frame = open.frame
        let right = try ink(folded)
        let columns = spreads(right, alongRows: false)
        #expect(columns.first > columns.last, "a folded chevron's left is \(columns.first) tall and its tip \(columns.last): not a >")
    }
}
