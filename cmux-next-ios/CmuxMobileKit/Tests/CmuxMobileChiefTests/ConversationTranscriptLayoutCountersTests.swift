import CmuxConversationGeometry
import CoreGraphics
import Testing

/// The transcript's offset index against a plain sequential sum, through
/// random measures, invalidations and batches of edits.
struct ConversationTranscriptOffsetsTests {
    struct Row: Equatable {
        var spacing: CGFloat
        var height: CGFloat
        var fresh: Bool
    }

    @Test func offsetsMatchASequentialSumThroughEdits() {
        var generator = SplitMix(seed: 7)
        var offsets = ConversationTranscriptOffsets()
        var model: [Row] = []
        offsets.reset(count: 300, estimate: 50)
        model = Array(repeating: Row(spacing: 0, height: 50, fresh: false), count: 300)
        for round in 0..<400 {
            switch generator.next() % 5 {
            case 0, 1:
                guard !model.isEmpty else { continue }
                let index = Int(generator.next() % UInt64(model.count))
                let spacing = CGFloat(generator.next() % 12), height = CGFloat(20 + generator.next() % 200) + 0.37
                offsets.setMeasured(index, spacing: spacing, height: height)
                model[index] = Row(spacing: spacing, height: height, fresh: true)
            case 2:
                offsets.invalidateAll()
                for index in model.indices { model[index].fresh = false }
            default:
                let deleteCount = model.isEmpty ? 0 : Int(generator.next() % 4)
                var deleted = Set<Int>()
                while deleted.count < deleteCount { deleted.insert(Int(generator.next() % UInt64(model.count))) }
                let remaining = model.count - deleted.count
                let insertCount = Int(generator.next() % 6)
                var inserted = Set<Int>()
                while inserted.count < insertCount { inserted.insert(Int(generator.next() % UInt64(remaining + insertCount))) }
                let followers = offsets.apply(deleted: Array(deleted), inserted: Array(inserted), estimate: 44)
                for index in deleted.sorted(by: >) { model.remove(at: index) }
                for index in inserted.sorted() { model.insert(Row(spacing: 0, height: 44, fresh: false), at: index) }
                for index in followers {
                    #expect(index > 0 || deleted.contains(0) || inserted.contains(0), "round \(round): follower \(index)")
                    #expect(!inserted.contains(index))
                }
            }
            #expect(offsets.count == model.count)
            var top: CGFloat = 0
            var stale = 0
            for (index, row) in model.enumerated() {
                top += index == 0 ? 0 : row.spacing
                #expect(abs(offsets.top(of: index) - top) < 0.001, "round \(round) row \(index): \(offsets.top(of: index)) vs \(top)")
                #expect(offsets.isFresh(index) == row.fresh, "round \(round) row \(index)")
                if !row.fresh { stale += 1 }
                top += row.height
                // The row at an offset: the first whose bottom is below it.
                #expect(offsets.firstRow(endingBelow: top - 0.01) == index, "round \(round) row \(index)")
            }
            #expect(abs(offsets.total - top) < 0.001)
            #expect(offsets.staleCount == stale, "round \(round)")
        }
    }

    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}

#if canImport(UIKit)
import UIKit
@testable import CmuxConversationUI

/// The layout's own counters per width change, at 1,000 and 10,000 rows:
/// attributes built and rows measured stay within the rows in view plus
/// overscan, no pass starts every row over, and the counts do not grow
/// with the conversation (see ConversationTranscriptVisibleRowsTests).
@MainActor
@Suite(.serialized)
struct ConversationTranscriptLayoutCountersTests {
    @Test func attributesAndRowsPerWidthChangeAreBoundedAndFlat() {
        var measured: [Int] = []
        var built: [Int] = []
        for count in [1_000, 10_000] {
            let rows = FakeTranscript(count: count)
            let layout = ConversationTranscriptLayout()
            layout.dataSource = rows
            let window = UIWindow(frame: CGRect(origin: .zero, size: ConversationTranscriptVisibleRowsTests.portrait))
            let view = UICollectionView(frame: window.bounds, collectionViewLayout: layout)
            view.register(UICollectionViewCell.self, forCellWithReuseIdentifier: FakeTranscript.reuseID)
            view.dataSource = rows
            window.addSubview(view)
            window.isHidden = false
            defer { window.isHidden = true }
            view.layoutIfNeeded()
            ConversationTranscriptVisibleRowsTests.pinToBottom(view)
            // Opening estimates every row once, without asking the data source.
            #expect(layout.counters.rowsEstimated == count)
            let before = layout.counters
            view.frame.size = ConversationTranscriptVisibleRowsTests.landscape
            view.reloadData()
            view.layoutIfNeeded()
            ConversationTranscriptVisibleRowsTests.pinToBottom(view)
            let after = layout.counters
            let budget = ConversationTranscriptVisibleRowsTests.budget(view, rows: rows)
            print("transcript-layout-counters N=\(count) width change: prepares=\(after.prepares - before.prepares) rowsMeasured=\(after.rowsMeasured - before.rowsMeasured) attributesBuilt=\(after.attributesBuilt - before.attributesBuilt) rowsEstimated=\(after.rowsEstimated - before.rowsEstimated) budget=\(budget)")
            #expect(after.rowsEstimated == before.rowsEstimated, "N=\(count): a width change started every row over")
            #expect(after.rowsMeasured - before.rowsMeasured <= budget, "N=\(count): rows measured \(after.rowsMeasured - before.rowsMeasured)")
            #expect(after.attributesBuilt - before.attributesBuilt <= 2 * budget, "N=\(count): attributes built \(after.attributesBuilt - before.attributesBuilt)")
            measured.append(after.rowsMeasured - before.rowsMeasured)
            built.append(after.attributesBuilt - before.attributesBuilt)
        }
        #expect(abs(measured[0] - measured[1]) <= max(2, max(measured[0], measured[1]) / 10), "rows measured \(measured)")
        #expect(abs(built[0] - built[1]) <= max(2, max(built[0], built[1]) / 10), "attributes built \(built)")
    }
}
#endif
