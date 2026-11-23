#if os(iOS)
@testable import CmuxMobileAgentChat
import Foundation
import Observation
import SwiftUI
import Testing
import UIKit

/// Work counters for the listperf windows #47189 missed at f34ddc61 (events-filter, events-burst,
/// the subagent-open window): what a keystroke, a frame of a burst and an open cost, counted
/// rather than timed.
@MainActor
@Suite struct ListWorkCountersTests {
    /// Counts redraws of what a screen's body reads: one per change it hears of, the observer
    /// registered again after each (as SwiftUI does on its next body pass).
    @MainActor final class Redraws {
        private(set) var count = 0
        private let read: @MainActor () -> Void

        init(_ read: @escaping @MainActor () -> Void) {
            self.read = read
            arm()
        }

        func arm() {
            withObservationTracking { read() } onChange: { [self] in
                Task { @MainActor in
                    self.count += 1
                    self.arm()
                }
            }
        }
    }

    static func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    // MARK: Event Inspector: a keystroke (EVT-9) and a burst (EVT-7)

    /// The events-filter case: 500 records with large ones among them, filtered off the main
    /// thread. Each keystroke redraws the list once, when its rows land: starting the filter
    /// changes nothing the list draws (the rows stay the last query's until then).
    @Test func aKeystrokeOnLargeRecordsRedrawsTheListOnce() async {
        let journal = AgentEventJournal()
        journal.nextFrame = nil
        let pad = String(repeating: "output line of a long tool result\n", count: 200)
        for n in 0..<500 { journal.record(EventInspectorCoalesceTests.record(n, body: n % 25 == 24 ? pad : nil)) }
        let rows = EventInspectorRows(offMainAbove: 0)
        rows.setQuery("", journal: journal)
        _ = rows.rows(journal)
        let redraws = Redraws { _ = rows.rows(journal) }
        var perKeystroke: [Int] = []
        for query in ["t", "to", "too", "tool", "tool_", "tool_call"] {
            let before = redraws.count
            rows.setQuery(query, journal: journal)
            await rows.settled()
            await Self.settle()
            perKeystroke.append(redraws.count - before)
            #expect(rows.rows(journal).map(\.id) == journal.events.filter { $0.matches(query) }.map(\.id))
        }
        #expect(perKeystroke.allSatisfy { $0 <= 1 }, "redraws of the list per keystroke: \(perKeystroke)")
    }

    /// The same keystrokes, counted where SwiftUI's List is built: the inspector's list view in
    /// a window, its body evaluations per keystroke (`EventInspectorList.bodies`). The filter
    /// text lives in the screen above it, so a keystroke itself does not evaluate the list.
    @Test func aKeystrokeEvaluatesTheListViewOnce() async {
        let journal = AgentEventJournal()
        journal.nextFrame = nil
        let pad = String(repeating: "output line of a long tool result\n", count: 200)
        for n in 0..<500 { journal.record(EventInspectorCoalesceTests.record(n, body: n % 25 == 24 ? pad : nil)) }
        let rows = EventInspectorRows(offMainAbove: 0)
        rows.setQuery("", journal: journal)
        let host = UIHostingController(rootView: NavigationStack { EventInspectorList(memo: rows, journal: journal, copied: .constant(false)) })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host
        window.isHidden = false
        ChatTranscriptSourceTests.settle(window)
        #expect(EventInspectorList.bodies > 0, "the list view was drawn")
        var perKeystroke: [Int] = []
        for query in ["t", "to", "too", "tool", "tool_", "tool_call"] {
            let before = EventInspectorList.bodies
            rows.setQuery(query, journal: journal)
            await rows.settled()
            await Self.settle()
            ChatTranscriptSourceTests.settle(window)
            perKeystroke.append(EventInspectorList.bodies - before)
        }
        window.isHidden = true
        #expect(perKeystroke.allSatisfy { $0 <= 1 } && perKeystroke.contains(1),
                "list view body evaluations per keystroke: \(perKeystroke)")
    }

    /// The events-burst case: 2000 records over 50 frames reach the list as at most one redraw
    /// a frame, with and without a filter.
    @Test(arguments: ["", "tool_call"])
    func aBurstRedrawsTheListAtMostOncePerFrame(_ query: String) async {
        let journal = AgentEventJournal()
        let frames = TestFrames()
        journal.nextFrame = { await frames.next() }
        let rows = EventInspectorRows(offMainAbove: .max)
        for n in 0..<500 { journal.record(EventInspectorCoalesceTests.record(n)) }
        await frames.fire()
        rows.setQuery(query, journal: journal)
        _ = rows.rows(journal)
        let redraws = Redraws { _ = rows.rows(journal) }
        let matchesBefore = rows.matchCalls
        for frame in 0..<50 {
            for n in 0..<40 { journal.record(EventInspectorCoalesceTests.record(500 + frame * 40 + n)) }
            await frames.fire()
            _ = rows.rows(journal)
            await Self.settle()
        }
        #expect(redraws.count <= 50, "50 frames of a burst redrew the list \(redraws.count) times")
        // A record costs one match with a filter (none without), never a pass over the list.
        #expect(rows.matchCalls - matchesBefore <= (query.isEmpty ? 0 : 2000))
    }

    // MARK: The subagent-open window (SUB-9)

    /// A finished 2000-item subagent: answers, thoughts and runs of tool calls.
    static func finishedLongStore(_ count: Int = 2000) -> AgentChatStore {
        let store = AgentChatStore(source: SmoothChatTests.Silent())
        store.nextFrame = nil
        store.apply(.subagent(AgentSubagentChange(id: "s", name: "Probe", task: "Check the transport", state: .running,
                                                  at: ChatTranscriptSourceTests.at)))
        for n in 0..<count {
            switch n % 5 {
            case 0: store.apply(.subagentUpdate(subagentID: "s", .agentMessageChunk(text: "Answer \(n): the dialer retries.", messageId: "m\(n)")))
            case 1: store.apply(.subagentUpdate(subagentID: "s", .agentThoughtChunk(text: "Thinking \(n)")))
            default: store.apply(.subagentUpdate(subagentID: "s", .toolCall(ACPToolCall(id: "c\(n)", title: "Read f\(n).swift", kind: .read,
                                                                                     status: .completed))))
            }
        }
        store.apply(.subagent(AgentSubagentChange(id: "s", state: .completed, at: ChatTranscriptSourceTests.at)))
        return store
    }

    /// About one display frame: the main actor is let go (the off-main layouts land on it, in a
    /// main-actor task; spinning the run loop inside this test's main-actor job never runs them),
    /// then the window is laid out.
    static func frame(_ window: UIWindow) async {
        try? await Task.sleep(for: .milliseconds(16))
        window.layoutIfNeeded()
    }

    /// An iPhone-sized window around the transcript host, laid out, with its off-main layouts
    /// landed: the first ones come, then none for 10 frames (at most 20 s).
    static func open(_ store: AgentChatStore) async -> (SubagentTranscriptHost, UIWindow) {
        let host = SubagentTranscriptHost(store: store, subagentID: "s")
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host
        window.isHidden = false
        for _ in 0..<6 { await frame(window) }
        let deadline = Date().addingTimeInterval(20)
        while host.list.layoutsMadeOffMain == 0, Date() < deadline { await frame(window) }
        var made = -1
        var still = 0
        while still < 10, Date() < deadline {
            await frame(window)
            if host.list.layoutsMadeOffMain == made { still += 1 } else { still = 0 }
            made = host.list.layoutsMadeOffMain
        }
        return (host, window)
    }

    /// Opening weighs each row once (compared, estimated, given its layout item), and a row
    /// whose native layout lands off the main thread once more: not every row for the list made
    /// without a width, again when the width comes, and again for each landing of its turn.
    @Test func openingALongTranscriptWeighsEachRowOnce() async {
        let store = Self.finishedLongStore()
        let (host, _) = await Self.open(store)
        let rows = host.list.layout.items.count
        let landed = host.list.layoutsMadeOffMain
        #expect(rows > 1000)
        #expect(landed > 0, "the off-main layouts landed (\(landed) in 20 s; \(host.list.layoutsMadeNow) made on the main thread)")
        let bar = rows + landed + 8
        #expect(host.list.rowsWeighed <= bar,
                "opening weighed \(host.list.rowsWeighed) rows (\(String(format: "%.1f", Double(host.list.rowsWeighed) / Double(max(rows, 1))))× its \(rows) rows; bar \(bar) = rows + \(landed) landed + 8)")
    }

    /// A finished transcript opens at its top: the rows laid out on the main thread are the
    /// ones on screen there, not its newest rows at the far end (those are laid out off the
    /// main thread, as the rest are).
    @Test func openingAFinishedTranscriptLaysOutOnlyItsTopOnTheMainThread() async {
        let store = Self.finishedLongStore()
        let (host, _) = await Self.open(store)
        let view = host.list.collectionView
        #expect(abs(view.contentOffset.y + view.adjustedContentInset.top) <= 0.5, "opens at the top")
        let visible = view.indexPathsForVisibleItems.count
        #expect(visible > 0)
        #expect(host.list.layoutsMadeNow <= visible + 4,
                "\(host.list.layoutsMadeNow) rows laid out on the main thread for \(visible) on screen")
    }
}
#endif
