import CmuxSwiftRender
import Foundation
import SwiftUI
import Testing
@testable import CmuxSwiftRenderUI

/// A custom sidebar re-renders once a second only when its source reads the
/// clock; every other sidebar re-renders only when its data changes.
@Suite("Custom sidebar clock timeline")
struct CustomSidebarClockTimelineTests {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000.25)

    @Test func clockFreeSidebarGetsOneTimelineEntry() {
        let schedule = CustomSidebarClockSchedule(ticksEverySecond: false)
        let entries = Array(schedule.entries(from: start, mode: .normal).prefix(5))
        #expect(entries == [start])
    }

    @Test func clockSidebarTicksOnWholeSeconds() {
        let schedule = CustomSidebarClockSchedule(ticksEverySecond: true)
        let entries = Array(schedule.entries(from: start, mode: .normal).prefix(4))
        #expect(entries == [
            start,
            Date(timeIntervalSinceReferenceDate: 800_000_001),
            Date(timeIntervalSinceReferenceDate: 800_000_002),
            Date(timeIntervalSinceReferenceDate: 800_000_003),
        ])
    }

    @Test @MainActor func onlySourcesThatReadTheClockTick() {
        let workspaces = "sidebar(() => data.workspaces().map(w => text(w.title)))"
        let clockJS = "sidebar(() => text(data.clock().time))"
        let clockSwift = "VStack { Text(clock.time) }"
        #expect(!CustomSidebarClockTimeline<EmptyView>.ticksEverySecond(for: .jsSource(workspaces)))
        #expect(CustomSidebarClockTimeline<EmptyView>.ticksEverySecond(for: .jsSource(clockJS)))
        #expect(CustomSidebarClockTimeline<EmptyView>.ticksEverySecond(for: .swiftSource(clockSwift)))
        #expect(!CustomSidebarClockTimeline<EmptyView>.ticksEverySecond(for: .missing))
        #expect(!CustomSidebarClockTimeline<EmptyView>.ticksEverySecond(for: .failed("clock")))
    }

    @Test func stockTemplatesWithoutClockDoNotTick() throws {
        // The bundled workspaces template was the reporter's 98% main-thread
        // repro: it never reads the clock, so it must not tick.
        let templates = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CmuxSwiftRenderUITests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // CmuxSwiftRenderUI
            .deletingLastPathComponent() // macOS
            .appendingPathComponent("CmuxSettings/Sources/CmuxSettings/Resources/CustomSidebarTemplates")
        let workspaces = try String(contentsOf: templates.appendingPathComponent("workspaces.js"), encoding: .utf8)
        let agentsBoard = try String(contentsOf: templates.appendingPathComponent("agents-board.js"), encoding: .utf8)
        #expect(!CustomSidebarClock.sourceReadsClock(workspaces))
        #expect(CustomSidebarClock.sourceReadsClock(agentsBoard))
    }

    @Test func mergingTheClockKeepsWorkspaceData() {
        let base: [String: SwiftValue] = ["workspaceCount": .int(3)]
        let calendar = Calendar(identifier: .gregorian)
        let merged = CustomSidebarClock.dataContext(base, at: Date(timeIntervalSince1970: 0), calendar: calendar)
        #expect(merged["workspaceCount"] == .int(3))
        #expect(merged["clock"]?.member("epoch") == .int(0))
    }
}
