import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import QuartzCore
import Testing

/// A selected tab opened at the end of a crowded strip moves with the strip's
/// one insert tween. Sample Core Animation's deterministic paths rather than
/// waiting for wall-clock frames, so a tab and the scroll cannot cross and
/// rewrite the trailing edge while the new tab grows into view.
@MainActor @Suite(.serialized) struct TabInsertFrameStabilityTests {
    private struct Sample {
        let frameX: CGFloat
        let contentX: CGFloat
    }

    @Test(arguments: [8, 20, 40])
    func anInsertedSelectedTabKeepsEveryFrameOnOneSlide(_ count: Int) throws {
        try TabCloseMotionTests.withMotion(reduce: false) {
            try #require(Motion.tabs.animatesMovement, "SETUP: animation speed is off on this host")
            let oldOverflow = DesignSettings.shared.tabOverflow
            DesignSettings.shared.tabOverflow = .shrink
            defer { DesignSettings.shared.tabOverflow = oldOverflow }

            let rig = TabCloseMotionTests.rig(TabCloseMotionTests.tabs(count), selected: TabID("tab0"))
            let strip = rig.strip
            rig.pane.setFrameSize(NSSize(width: 520, height: 300))
            rig.pane.layoutSubtreeIfNeeded()
            try #require(strip.result.isOverflowing, "SETUP: \(count) tabs fit in the 520 pt strip")

            let oldIDs = rig.model.tabs.map(\.id)
            let previousID = try #require(oldIDs.first, "SETUP: no previously selected tab")
            let newID = TabID("new-selected")
            rig.model.tabs.append(TabItem(id: newID, title: "New Tab"))
            rig.model.selectedID = newID
            strip.sync(fromModel: true)

            let oldCells = try oldIDs.map { id in try #require(strip.cells[id], "\(id.rawValue) has no cell") }
            let previousCell = try #require(strip.cells[previousID])
            let newCell = try #require(strip.cells[newID], "the selected tab has no cell")
            let movingCells = oldCells + [newCell]
            let begin = try #require(TabCloseMotionTests.latestMoveBegin(movingCells), "the insert started no strip move")
            let scrollPath = MotionPath(strip.scrollProbe, "position", now: begin)
            let end = try #require((movingCells.flatMap { cell in
                [MotionPath(cell.layer, "position", now: begin).end, MotionPath(cell.layer, "bounds.size", now: begin).end]
            } + [scrollPath.end]).compactMap { $0 }.max(), "the insert has no end time")
            try #require(end - begin > 1.0 / 120, "the insert did not animate")
            try #require(strip.scrollOffset > 0, "the selected last tab did not need a reveal")

            let times = MotionPath.times(from: begin, to: end + 1.0 / 120,
                                         count: MotionPath.sampleCount(seconds: end - begin + 1.0 / 120))
            @MainActor func sample(_ cell: TabCell, at time: CFTimeInterval) -> Sample {
                let frame = TabStripMove.shownFrame(cell.layer, at: time)
                let scrollPart = scrollPath.value(at: time).x - scrollPath.model.x
                return Sample(frameX: frame.minX, contentX: frame.minX + strip.scrollOffset - scrollPart)
            }

            func assertOneWay(_ values: [CGFloat], label: String) {
                guard let first = values.first, let last = values.last else { return }
                let travel = last - first
                let direction: CGFloat = travel < 0 ? -1 : 1
                let low = min(first, last) - 1
                let high = max(first, last) + 1
                for index in values.indices.dropFirst() {
                    let value = values[index]
                    let prior = values[index - 1]
                    let step = value - prior
                    let remaining = last - prior
                    if abs(travel) > 0.01 {
                        #expect(step * direction >= -0.01,
                        "\(label) reversed at sample \(index): \(prior) -> \(value), target \(last)")
                        #expect(step * direction <= abs(remaining) + 1,
                                "\(label) jumped \(step) pt past its intended slide at sample \(index)")
                    }
                    #expect(value >= low && value <= high,
                            "\(label) left its intended slide at sample \(index): \(value), \(first) -> \(last)")
                }
            }

            for (id, cell) in zip(oldIDs, oldCells) {
                let samples = times.map { sample(cell, at: $0) }
                assertOneWay(samples.map(\.contentX), label: "\(id.rawValue) content x")
            }
            let previousSamples = times.map { sample(previousCell, at: $0) }
            let newSamples = times.map { sample(newCell, at: $0) }
            assertOneWay(previousSamples.map(\.frameX), label: "\(previousID.rawValue) frame x")
            assertOneWay(newSamples.map(\.frameX), label: "\(newID.rawValue) frame x")
            assertOneWay(newSamples.map(\.contentX), label: "\(newID.rawValue) content x")

            let finalFrame = TabStripMove.shownFrame(newCell.layer, at: times.last ?? end)
            #expect(finalFrame.minX >= strip.tabsClip.bounds.minX - 0.5,
                    "the new tab starts before the viewport: \(finalFrame)")
            #expect(finalFrame.maxX <= strip.tabsClip.bounds.maxX + 0.5,
                    "the new tab ends after the viewport: \(finalFrame)")
        }
    }
}
