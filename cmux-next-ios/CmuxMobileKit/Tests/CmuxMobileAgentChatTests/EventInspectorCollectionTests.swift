#if os(iOS)
@testable import CmuxMobileAgentChat
import Foundation
import SwiftUI
import Testing
import UIKit

/// The Event Inspector's UIKit list (#47189 r3: events-filter, the burst at the top, the held
/// batch): an update is one apply of the rows that changed, and a row measured once is not
/// measured again.
@MainActor
@Suite(.serialized) struct EventInspectorCollectionTests {
    static func journal(_ count: Int, from start: Int = 0) -> AgentEventJournal {
        let journal = AgentEventJournal()
        journal.nextFrame = nil
        for n in start..<(start + count) { journal.record(EventInspectorCoalesceTests.record(n)) }
        return journal
    }

    /// The list in an iPhone-sized window, laid out.
    static func host(_ list: EventInspectorCollection) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        let controller = UIViewController()
        list.collectionView.frame = controller.view.bounds
        list.collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view.addSubview(list.collectionView)
        window.rootViewController = controller
        window.isHidden = false
        ChatTranscriptSourceTests.settle(window)
        return window
    }

    static func newestFirst(_ rows: EventInspectorRows, _ journal: AgentEventJournal) -> [AgentInspectorEvent] {
        Array(rows.rows(journal).reversed())
    }

    /// A keystroke's rows landing: one apply, of exactly the rows that left or came (the rows
    /// both queries match are not inserted, removed or redrawn again).
    @Test func aKeystrokeLandingIsOneApplyOfTheChangedRows() {
        let journal = Self.journal(500)
        let rows = EventInspectorRows(offMainAbove: .max)
        rows.setQuery("", journal: journal)
        let list = EventInspectorCollection()
        let window = Self.host(list)
        list.show(Self.newestFirst(rows, journal), summary: "500 events")
        ChatTranscriptSourceTests.settle(window)
        var shown = Set(Self.newestFirst(rows, journal).map(\.id))
        for query in ["t", "to", "too", "tool", "tool_", "tool_call", ""] {
            let applies = list.applies
            rows.setQuery(query, journal: journal)
            let next = Self.newestFirst(rows, journal)
            list.show(next, summary: "")
            ChatTranscriptSourceTests.settle(window)
            let now = Set(next.map(\.id))
            let changed = shown.symmetricDifference(now)
            #expect(list.applies - applies == (changed.isEmpty ? 0 : 1), "'\(query)': \(list.applies - applies) applies")
            #expect(list.lastChanged == changed || changed.isEmpty,
                    "'\(query)': the apply changed \(list.lastChanged.count) rows; \(changed.count) left or came")
            shown = now
        }
    }

    /// A row a cell measured is not measured again: not when its records come back after a
    /// filter, and not when the reader scrolls it away and back.
    @Test func aMeasuredRowIsNotMeasuredAgain() {
        let journal = Self.journal(500)
        let rows = EventInspectorRows(offMainAbove: .max)
        rows.setQuery("", journal: journal)
        let list = EventInspectorCollection()
        let window = Self.host(list)
        list.show(Self.newestFirst(rows, journal), summary: "500 events")
        ChatTranscriptSourceTests.settle(window)
        let first = list.sizingPasses
        #expect(first > 0, "the rows on screen were measured")
        // A filter and its clearing: the same records come back.
        rows.setQuery("tool_call", journal: journal)
        list.show(Self.newestFirst(rows, journal), summary: "")
        ChatTranscriptSourceTests.settle(window)
        let afterFilter = list.sizingPasses
        rows.setQuery("", journal: journal)
        list.show(Self.newestFirst(rows, journal), summary: "")
        ChatTranscriptSourceTests.settle(window)
        // Away and back.
        let view = list.collectionView
        view.setContentOffset(CGPoint(x: 0, y: 4000), animated: false)
        ChatTranscriptSourceTests.settle(window)
        let away = list.sizingPasses
        view.setContentOffset(CGPoint(x: 0, y: -view.adjustedContentInset.top), animated: false)
        ChatTranscriptSourceTests.settle(window)
        #expect(list.sizingPasses == away,
                "rows scrolled back into view were measured again: \(list.sizingPasses - away) sizing passes")
        #expect(afterFilter - first <= 20, "a filter measured \(afterFilter - first) rows (only rows new to the screen may be)")
    }

    /// The burst at the top: 2000 records over 50 frames reach the screen as at most one apply
    /// a frame, each of the frame's rows only (40 in, 40 out), never the whole list again.
    @Test func aBurstFrameIsOneApplyOfItsRows() async {
        let journal = AgentEventJournal()
        let frames = TestFrames()
        journal.nextFrame = { await frames.next() }
        for n in 0..<500 { journal.record(EventInspectorCoalesceTests.record(n)) }
        await frames.fire()
        let rows = EventInspectorRows(offMainAbove: .max)
        rows.setQuery("", journal: journal)
        let probe = RenderProbe()
        let host = UIHostingController(rootView: NavigationStack {
            EventInspectorList(memo: rows, journal: journal, copied: .constant(false))
        }.environment(\.renderProbe, probe))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host
        window.isHidden = false
        for _ in 0..<6 { await ListWorkCountersTests.frame(window) }
        var perFrame: [Int] = []
        var changed: [Int] = []
        for frame in 0..<50 {
            for n in 0..<40 { journal.record(EventInspectorCoalesceTests.record(500 + frame * 40 + n)) }
            let before = probe.inspectorApplies
            await frames.fire()
            await ListWorkCountersTests.frame(window)
            perFrame.append(probe.inspectorApplies - before)
            if probe.inspectorApplies > before { changed.append(probe.inspectorLastChanged) }
        }
        window.isHidden = true
        #expect(perFrame.allSatisfy { $0 <= 1 }, "applies per frame: \(perFrame)")
        #expect(changed.allSatisfy { $0 <= 80 }, "rows changed per frame's apply: \(changed)")
    }
}
#endif
