import CoreGraphics
import Testing
@testable import CmuxConversationGeometry

@Suite struct ConversationReuseClassTests {
    /// A deterministic generator, so a failure replays.
    struct Rng {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    /// Message rows as a transcript mixes them: mostly one to three lines,
    /// some long messages, link cards and photos, the odd very long one.
    func transcript(count: Int, rng: inout Rng) -> [CGFloat] {
        (0..<count).map { _ in
            let roll = rng.next()
            switch roll {
            case ..<0.55: return 36.33 + 20.33 * CGFloat(Int(rng.next() * 3))
            case ..<0.8: return 90 + CGFloat(rng.next()) * 160
            case ..<0.95: return 250 + CGFloat(rng.next()) * 450
            default: return 700 + CGFloat(rng.next()) * 1500
            }
        }
    }

    /// Scrolls `heights` (rows `gap` apart) up and down through a viewport
    /// `viewport` tall and replays UIKit's reuse queues: a row coming on
    /// screen takes a queued cell of its class or builds one; a row leaving
    /// queues its cell unless the queue is full (`queueLimit`), when the
    /// cell is dropped. Returns the cells built and dropped after `warmUp`
    /// passes.
    func replay(_ heights: [CGFloat], gap: CGFloat, viewport: CGFloat, passes: Int, warmUp: Int, classOf: (CGFloat) -> Int) -> (built: Int, dropped: Int) {
        var tops: [CGFloat] = []
        var y: CGFloat = 0
        for height in heights {
            tops.append(y)
            y += height + gap
        }
        let contentHeight = y
        var queues: [Int: Int] = [:]
        var visible: Set<Int> = []
        var built = 0, dropped = 0
        func visit(_ offset: CGFloat, counting: Bool) {
            var low = 0, high = heights.count
            while low < high {
                let mid = (low + high) / 2
                if tops[mid] + heights[mid] <= offset { low = mid + 1 } else { high = mid }
            }
            var now: Set<Int> = []
            while low < heights.count, tops[low] < offset + viewport {
                now.insert(low)
                low += 1
            }
            // Leaving first, as UICollectionView's visible-cells pass does.
            for row in visible.subtracting(now).sorted() {
                let queue = classOf(heights[row])
                if queues[queue, default: 0] < ConversationReuseClass.queueLimit(cellHeight: heights[row], viewportHeight: viewport) {
                    queues[queue, default: 0] += 1
                } else if counting {
                    dropped += 1
                }
            }
            for row in now.subtracting(visible).sorted() {
                let queue = classOf(heights[row])
                if queues[queue, default: 0] > 0 {
                    queues[queue]! -= 1
                } else if counting {
                    built += 1
                }
            }
            visible = now
        }
        // The first pass creeps, so it meets every screenful once.
        let speeds: [CGFloat] = [0.5, 17, 60, 140, 400, 3]
        for pass in 0..<passes {
            let speed = speeds[pass % speeds.count]
            var offset: CGFloat = 0
            while offset < contentHeight - viewport {
                visit(offset, counting: pass >= warmUp)
                offset += speed
            }
            while offset > 0 {
                visit(offset, counting: pass >= warmUp)
                offset -= speed
            }
        }
        return (built, dropped)
    }

    /// UIKit's own numbers: a 253 pt row on a 956 pt screen keeps at most
    /// 6 cells queued (ceil(1.5 * 956 / 253) + 1 = 7 views).
    @Test func uiKitKeepsAboutOneAndAHalfScreensOfCellsQueued() {
        #expect(ConversationReuseClass.queueLimit(cellHeight: 253, viewportHeight: 956) == 7)
        #expect(ConversationReuseClass.queueLimit(cellHeight: 36.33, viewportHeight: 956) == 41)
        #expect(ConversationReuseClass.queueLimit(cellHeight: 2000, viewportHeight: 956) == 2)
    }

    /// One queue for every message row: scrolling back and forth keeps
    /// dropping tall rows' cells and building new ones (what the transcript
    /// did, ~50 cells per 4 min of scrolling on iOS 27.0).
    @Test func oneQueueForEveryRowKeepsBuildingCells() {
        var rng = Rng(state: 7)
        let heights = transcript(count: 400, rng: &rng)
        let result = replay(heights, gap: 2, viewport: 956, passes: 6, warmUp: 1) { _ in 0 }
        #expect(result.dropped > 0)
        #expect(result.built > 0)
    }

    /// Rows queued by how many of them fit on screen: after one pass down
    /// and up, scrolling reuses every cell and builds none.
    @Test(arguments: [874.0, 956.0, 1194.0, 500.0] as [CGFloat], [1, 7, 42] as [UInt64])
    func reuseClassesKeepEveryCellOnceWarm(viewport: CGFloat, seed: UInt64) {
        var rng = Rng(state: seed)
        let heights = transcript(count: 400, rng: &rng)
        let result = replay(heights, gap: 1, viewport: viewport, passes: 6, warmUp: 1) {
            ConversationReuseClass.index(rowHeight: $0, viewportHeight: viewport)
        }
        #expect(result.dropped == 0)
        #expect(result.built == 0)
    }

    /// Each class's rows fit on screen at most as many times as UIKit lets
    /// its queue hold the class's tallest row.
    @Test func everyClassFitsUIKitsQueueLimit() {
        let viewport: CGFloat = 956
        var height: CGFloat = 24
        var byClass: [Int: (min: CGFloat, max: CGFloat)] = [:]
        while height < 3000 {
            let index = ConversationReuseClass.index(rowHeight: height, viewportHeight: viewport)
            #expect(index >= 0 && index < ConversationReuseClass.count)
            let bounds = byClass[index] ?? (height, height)
            byClass[index] = (min(bounds.min, height), max(bounds.max, height))
            height += 0.25
        }
        for (_, bounds) in byClass {
            // Rows at least `min` tall: at most floor(viewport / min) whole
            // ones on screen plus one cut at each edge, all but one queued
            // when the last leaves.
            let mostOnScreen = Int((viewport / bounds.min).rounded(.down)) + 2
            #expect(mostOnScreen - 1 < ConversationReuseClass.queueLimit(cellHeight: bounds.max, viewportHeight: viewport))
        }
        #expect(byClass.count > 1)
    }
}

/// A row's cell must be dequeued again with the class it came from while
/// UIKit holds it: reconfiguring with another raises
/// NSInternalInconsistencyException ("Attempted to dequeue a cell for a
/// different registration or reuse identifier than the existing cell when
/// reconfiguring an item"), seen in a live conversation (iOS 27.0 sim).
@Suite struct ConversationReuseRegistryTests {
    /// A cell that scrolled away still shows a row that got a second cell;
    /// reusing the first cell for another row must not forget the class
    /// the second one came from.
    @Test func aStaleCellMovingOnKeepsTheRowsCurrentClass() {
        var registry = ConversationReuseRegistry<Int>()
        registry.dequeued(1, forRow: "x", reuseClass: 6, previousRowID: nil)
        // x is prefetched again into a second cell, with x's class.
        let again = registry.reuseClass(forRow: "x") ?? 4
        registry.dequeued(2, forRow: "x", reuseClass: again, previousRowID: nil)
        // The first cell, still showing x, is reused for y.
        registry.dequeued(1, forRow: "y", reuseClass: 4, previousRowID: "x")
        // x grew or shrank; its cell (2) must still come from class 6.
        #expect(registry.reuseClass(forRow: "x") == 6)
        #expect(registry.reuseClass(forRow: "y") == 4)
    }

    @Test func theCellThatLastShowedARowFreesIt() {
        var registry = ConversationReuseRegistry<Int>()
        registry.dequeued(1, forRow: "x", reuseClass: 6, previousRowID: nil)
        registry.dequeued(1, forRow: "y", reuseClass: 4, previousRowID: "x")
        #expect(registry.reuseClass(forRow: "x") == nil)
        registry.dequeued(1, forRow: "y", reuseClass: 4, previousRowID: "y")
        #expect(registry.reuseClass(forRow: "y") == 4)
        registry.forget(rowID: "y")
        #expect(registry.reuseClass(forRow: "y") == nil)
        registry.dequeued(3, forRow: "z", reuseClass: 2, previousRowID: nil)
        registry.forgetAll()
        #expect(registry.reuseClass(forRow: "z") == nil)
    }
}
