import AppKit
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// Leo 2026-11-10 (ask-7778f8202e): "our fucking thing is too slow to scroll through the side bar /
/// where's our performance". A scroll under a still pointer moves the hover to a new row almost every
/// frame. Each hovered row used to tell the app at once: the chat page on screen got a
/// `chat.prefetch` script (`AgentPaneView.forwardHover`, an `evaluateScript` into the page's renderer)
/// and hibernation got a hover intent, once per row the scroll passed, so every scroll frame did
/// cross-process work. Chromium holds hover updates during a scroll and sends one fake mouse move after
/// it settles; the sidebar does the same: the hover pill still follows the rows, and the row under the
/// pointer is reported once, after the scroll rests (`SidebarListView.scrollHoverSettle`).
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)))
struct SidebarScrollHoverForwardTests {
    final class Forwards {
        var tabs: [TabID?] = []
        var workspaces: [WorkspaceID?] = []
    }

    static func bench(_ forwards: Forwards) -> SidebarScrollBench {
        let bench = SidebarScrollBench(count: 200, pointerOverList: true)
        bench.list.onHoverTab = { forwards.tabs.append($0) }
        bench.list.onHoverWorkspace = { forwards.workspaces.append($0) }
        return bench
    }

    /// A scroll that moves dozens of rows under the pointer forwards none of them while it runs, and
    /// the row under the pointer once it rests.
    @Test func aScrollUnderAStillPointerForwardsOnlyTheRowItRestsOn() async throws {
        let forwards = Forwards()
        let bench = Self.bench(forwards)
        defer { bench.close() }
        bench.list.scrollHoverSettle = .milliseconds(1)
        var passed = Set<SidebarRowKey>()
        var y: CGFloat = 0
        for _ in 0..<40 {
            y += 40
            _ = bench.frame(to: y)
            if let key = bench.list.hoveredKey { passed.insert(key) }
        }
        #expect(passed.count >= 10, "the scroll moved the hover over only \(passed.count) rows")
        #expect(forwards.workspaces.isEmpty, "a scroll forwarded \(forwards.workspaces.count) hovered rows while it ran")
        #expect(forwards.tabs.isEmpty, "a scroll sent \(forwards.tabs.count) chat prefetches while it ran")

        // The settle timer forwards the rested row: wait for that forward, bounded by a deadline, not a fixed sleep.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while forwards.workspaces.isEmpty, clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let rested = bench.list.hoveredKey
        let restedWorkspace: WorkspaceID? = if case let .workspace(id)? = rested { id } else { nil }
        #expect(forwards.workspaces.count == 1, "after the scroll rested: \(forwards.workspaces)")
        #expect(forwards.workspaces.last == restedWorkspace)
    }

    /// The pointer's own move still forwards its row at once: only rows a scroll moves under a still
    /// pointer wait for the scroll to rest.
    @Test func aPointerMoveForwardsItsRowAtOnce() throws {
        let forwards = Forwards()
        let bench = Self.bench(forwards)
        defer { bench.close() }
        let list = bench.list
        let row = try #require(list.displayed.rows.first { if case .workspace = $0.key { true } else { false } })
        let frame = list.frame(for: row)
        let windowPoint = list.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
        list.updateHover(windowPoint)
        #expect(list.hoveredKey == row.key)
        #expect(forwards.workspaces.count == 1, "a pointer move forwarded \(forwards.workspaces)")
    }
}
