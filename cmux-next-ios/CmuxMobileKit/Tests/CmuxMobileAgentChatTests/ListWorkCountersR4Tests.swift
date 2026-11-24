#if os(iOS)
@testable import CmuxMobileAgentChat
import Foundation
import SwiftUI
import Testing
import UIKit

/// Work counters for #47189's r4 changes (the inspector's list view, the subagent transcript's
/// open window, the Subagents rows). They read types base does not have, so they live apart
/// from ListWorkCountersTests (the counter red's file, kept as it is on base). Each test reads
/// the counters of the screen it hosts (`RenderProbe`): tests run at once and must not count
/// each other's work.
@MainActor
@Suite(.serialized) struct ListWorkCountersR4Tests {
    static func frame(_ window: UIWindow) async { await ListWorkCountersTests.frame(window) }

    static func window(_ root: some View, probe: RenderProbe) -> UIWindow {
        let host = UIHostingController(rootView: NavigationStack { root }.environment(\.renderProbe, probe))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host
        window.isHidden = false
        return window
    }

    // MARK: The Event Inspector's list view

    /// The keystrokes of aKeystrokeOnLargeRecordsRedrawsTheListOnce, counted where SwiftUI builds
    /// the list: the list view's body evaluations per keystroke (the filter text lives in the
    /// screen above it, so a keystroke itself does not evaluate the list).
    @Test func aKeystrokeEvaluatesTheListViewOnce() async {
        let journal = AgentEventJournal()
        journal.nextFrame = nil
        let pad = String(repeating: "output line of a long tool result\n", count: 200)
        for n in 0..<500 { journal.record(EventInspectorCoalesceTests.record(n, body: n % 25 == 24 ? pad : nil)) }
        let rows = EventInspectorRows(offMainAbove: 0)
        rows.setQuery("", journal: journal)
        let probe = RenderProbe()
        let window = Self.window(EventInspectorList(memo: rows, journal: journal, copied: .constant(false)), probe: probe)
        for _ in 0..<6 { await Self.frame(window) }
        #expect(probe.inspectorListBodies > 0, "the list view was drawn")
        var perKeystroke: [Int] = []
        for query in ["t", "to", "too", "tool", "tool_", "tool_call"] {
            let before = probe.inspectorListBodies
            rows.setQuery(query, journal: journal)
            await rows.settled()
            await ListWorkCountersTests.settle()
            for _ in 0..<3 { await Self.frame(window) }
            perKeystroke.append(probe.inspectorListBodies - before)
        }
        window.isHidden = true
        #expect(perKeystroke.allSatisfy { $0 <= 1 } && perKeystroke.contains(1),
                "list view body evaluations per keystroke: \(perKeystroke)")
    }

    // MARK: The subagent transcript's open (#47189 r3: subagent-2000, subagent-stream)

    /// A running subagent with `count` items.
    static func runningLongStore(_ count: Int) -> AgentChatStore {
        let store = ListWorkCountersTests.finishedLongStore(count)
        store.apply(.subagent(AgentSubagentChange(id: "s", state: .running, at: ChatTranscriptSourceTests.at)))
        return store
    }

    /// The host in an iPhone-sized window after its first layouts only (what the open costs).
    static func openNow(_ store: AgentChatStore, windowed: Bool = true) -> (SubagentTranscriptHost, UIWindow) {
        let host = SubagentTranscriptHost(store: store, subagentID: "s", windowed: windowed)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host
        window.isHidden = false
        ChatTranscriptSourceTests.settle(window)
        return (host, window)
    }

    /// Frames until every chunk is in and the off-main layouts stopped landing (at most 30 s).
    static func fill(_ host: SubagentTranscriptHost, _ window: UIWindow) async {
        let deadline = Date().addingTimeInterval(30)
        while !host.filled, Date() < deadline { await frame(window) }
        var made = -1
        var shown = -1
        var still = 0
        while still < 10, Date() < deadline {
            await frame(window)
            let now = (host.list.layoutsMadeOffMain, host.list.layout.items.count)
            if now.0 == made, now.1 == shown { still += 1 } else { still = 0 }
            (made, shown) = now
        }
    }

    /// A finished 2000-item transcript's open weighs the rows at its top, not all of them.
    @Test func openingALongFinishedTranscriptWeighsItsTopOnly() {
        let (host, _) = Self.openNow(ListWorkCountersTests.finishedLongStore())
        let visible = host.list.collectionView.indexPathsForVisibleItems.count
        #expect(visible > 0)
        #expect(host.list.rowsWeighed <= 200,
                "the open weighed \(host.list.rowsWeighed) rows on the main thread for \(visible) on screen")
    }

    /// A running transcript's open lays out on the main thread the rows one screen holds at its end.
    @Test func openingARunningTranscriptLaysOutOneScreenOnTheMainThread() {
        let (host, _) = Self.openNow(Self.runningLongStore(200))
        let visible = host.list.collectionView.indexPathsForVisibleItems.count
        #expect(visible > 0)
        #expect(host.list.layoutsMadeNow <= visible + 4,
                "\(host.list.layoutsMadeNow) rows laid out on the main thread at the open for \(visible) on screen, by path: \(host.list.layoutsMadeNowBy.sorted { $0.key < $1.key })")
    }

    /// Older rows put in above a running end move nothing the reader sees (0.5 pt), frame after
    /// frame, and the end is still followed.
    @Test func olderRowsPutInAboveARunningEndMoveNothing() async {
        let (host, window) = Self.openNow(Self.runningLongStore(2000))
        let view = host.list.collectionView
        func lastOnScreen() -> (id: Int, y: CGFloat)? {
            let paths = view.indexPathsForVisibleItems.sorted()
            guard let path = paths.last, let cell = view.cellForItem(at: path) else { return nil }
            return (path.item, cell.convert(cell.bounds, to: window).maxY)
        }
        guard let start = lastOnScreen() else { Issue.record("no row on screen"); return }
        var worst: CGFloat = 0
        for _ in 0..<40 {
            await Self.frame(window)
            guard let now = lastOnScreen() else { continue }
            worst = max(worst, abs(now.y - start.y))
        }
        #expect(worst <= 0.5, "the end on screen moved \(worst) pt while older rows came in above it")
        #expect(host.follows, "the reader still follows the end")
    }

    /// A row streamed onto a running end after the open is still laid out on the spot (the rows
    /// a growth puts in above are history, laid out off the main thread).
    @Test func aRowStreamedAfterTheOpenIsLaidOutOnTheSpot() async {
        let store = Self.runningLongStore(200)
        let (host, window) = Self.openNow(store)
        await Self.fill(host, window)
        let before = host.list.layoutsMadeNow
        store.apply(.subagentUpdate(subagentID: "s", .agentMessageChunk(text: "A new answer streams in", messageId: "streamed")))
        for _ in 0..<4 { await Self.frame(window) }
        #expect(host.list.layoutsMadeNow > before, "the streamed row was laid out on the spot (\(host.list.layoutsMadeNow - before))")
    }

    /// After every chunk is in, a windowed transcript lays out as the transcript shown whole:
    /// every row at the same place and height (0.5 pt), finished (grown below its top) and
    /// running (grown above its end).
    @Test(arguments: [false, true])
    func aGrownWindowLaysOutAsTheWholeTranscript(_ running: Bool) async {
        func store() -> AgentChatStore { running ? Self.runningLongStore(600) : ListWorkCountersTests.finishedLongStore(600) }
        let (whole, wholeWindow) = Self.openNow(store(), windowed: false)
        await Self.fill(whole, wholeWindow)
        let (grown, grownWindow) = Self.openNow(store())
        await Self.fill(grown, grownWindow)
        let a = whole.list.layout.items
        let b = grown.list.layout.items
        #expect(a.count == b.count, "rows: \(b.count) windowed, \(a.count) whole")
        var worst: CGFloat = 0
        var at = -1
        for index in 0..<min(a.count, b.count) {
            guard let ta = whole.list.layout.top(of: a[index].id), let tb = grown.list.layout.top(of: b[index].id),
                  let ha = whole.list.layout.height(of: a[index].id), let hb = grown.list.layout.height(of: b[index].id) else { continue }
            let off = max(abs(ta - tb), abs(ha - hb))
            if off > worst { worst = off; at = index }
        }
        wholeWindow.isHidden = true
        grownWindow.isHidden = true
        #expect(worst <= 0.5, "row \(at) is \(worst) pt off the whole transcript's layout")
    }

    /// The main thread's time per chunk of a growing transcript (finished: below its top;
    /// running: above its end), bounded by half a frame. The numbers are attached
    /// ("subagent-chunk"): the chunk size is picked from them.
    @Test(arguments: [false, true])
    func eachChunkFitsAFrame(_ running: Bool) async {
        let store = running ? Self.runningLongStore(2000) : ListWorkCountersTests.finishedLongStore()
        let (host, window) = Self.openNow(store)
        func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
        var times: [Double] = []
        var weighed: [Int] = []
        var parts: [String] = []
        var chunks = host.chunks
        var time = host.list.reloadTime
        var rows = host.list.rowsWeighed
        var sections = host.list.sectionTimes
        let deadline = Date().addingTimeInterval(30)
        while !host.filled, Date() < deadline {
            await Self.frame(window)
            guard host.chunks != chunks else { continue }
            chunks = host.chunks
            let spent = host.list.reloadTime - time
            times.append(Double(spent.components.attoseconds) / 1e15 + Double(spent.components.seconds) * 1000)
            weighed.append(host.list.rowsWeighed - rows)
            let now = host.list.sectionTimes
            parts.append(now.keys.sorted().map { "\($0)=\(String(format: "%.1f", ms(now[$0]! - (sections[$0] ?? .zero))))" }.joined(separator: ","))
            sections = now
            time = host.list.reloadTime
            rows = host.list.rowsWeighed
        }
        let worst = times.max() ?? 0
        let perRow = zip(times, weighed).map { $1 > 0 ? $0 / Double($1) : 0 }.max() ?? 0
        let summary = "running=\(running) chunk=\(SubagentRowWindow.chunk) chunks=\(times.count) worst_ms=\(String(format: "%.2f", worst)) worst_ms_per_row=\(String(format: "%.3f", perRow)) ms=\(times.map { String(format: "%.1f", $0) }) weighed=\(weighed) parts=\(parts)"
        Attachment.record(summary, named: "subagent-chunk-\(running ? "running" : "finished")")
        window.isHidden = true
        #expect(host.filled, "every chunk came in: \(summary)")
        #expect(worst <= 8, "a chunk took \(String(format: "%.1f", worst)) ms on the main thread: \(summary)")
    }

    // MARK: The Subagents list (#47189 r3: subagents-list-60)

    /// 60 subagents, one changing: the list evaluates that row, not all 60.
    @Test func aSubagentChangeEvaluatesItsRowOnly() async {
        let store = AgentChatStore(source: SmoothChatTests.Silent())
        store.nextFrame = nil
        let running = ListStressChatScreens.seedSubagents(store, count: 60)
        #expect(!running.isEmpty)
        let probe = RenderProbe()
        let window = Self.window(SubagentsScreen(store: store, surface: AgentChatSurface()), probe: probe)
        for _ in 0..<6 { await Self.frame(window) }
        #expect(probe.subagentRowBodies > 0, "the rows were drawn")
        var perChange: [Int] = []
        for tick in 0..<4 {
            let before = probe.subagentRowBodies
            store.apply(.subagentUpdate(subagentID: running[0], .toolCall(ACPToolCall(id: "tick-\(tick)", title: "Run step \(tick)",
                                                                                      kind: .execute))))
            for _ in 0..<3 { await Self.frame(window) }
            perChange.append(probe.subagentRowBodies - before)
        }
        window.isHidden = true
        #expect(perChange.allSatisfy { $0 <= 2 }, "row body evaluations per change of one subagent: \(perChange)")
    }

    /// A running subagent's time advances with nothing changing in the store (its own clock).
    @Test func aRunningSubagentsTimeAdvancesInAQuietStore() async {
        let store = AgentChatStore(source: SmoothChatTests.Silent())
        store.nextFrame = nil
        store.apply(.subagent(AgentSubagentChange(id: "q", name: "Quiet", task: "Wait", state: .running, at: Date())))
        let probe = RenderProbe()
        let window = Self.window(SubagentsScreen(store: store, surface: AgentChatSurface()), probe: probe)
        for _ in 0..<6 { await Self.frame(window) }
        let rows = probe.subagentRowBodies
        let ticks = probe.subagentClockTicks
        let deadline = Date().addingTimeInterval(2.5)
        while Date() < deadline { await Self.frame(window) }
        window.isHidden = true
        #expect(probe.subagentClockTicks - ticks >= 2, "the running time drew \(probe.subagentClockTicks - ticks) times in 2.5 s with no change")
        #expect(probe.subagentRowBodies == rows, "the row itself was not evaluated again (\(probe.subagentRowBodies - rows))")
    }
}
#endif
