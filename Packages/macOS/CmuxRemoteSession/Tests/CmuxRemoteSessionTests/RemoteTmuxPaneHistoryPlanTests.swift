import CmuxRemoteSession
import Foundation
import Testing

/// The capture ranges that read a mirrored pane's whole tmux history in pieces small enough
/// for the control stream.
@Suite struct RemoteTmuxPaneHistoryPlanTests {
    /// The app's control stream treats a command block over 16 MiB as broken.
    private static let commandBlockBytes = 16_777_216

    @Test func historyIsReadOldestFirstInChunksThatEndAtTheNewestRow() {
        // 400,000 cells per chunk: 2,000 rows at 200 columns.
        let plan = RemoteTmuxPaneHistoryPlan(
            historySize: 5_000, paneWidth: 200, maximumCommandBlockBytes: 400_000 * 128)
        #expect(plan.chunks == [
            .init(start: "-", end: "-3001"),
            .init(start: "-3000", end: "-1001"),
            .init(start: "-1000", end: "-1"),
        ])
        #expect(plan.historyRows == 5_000)
        #expect(!plan.isTruncated)
    }

    @Test func aWidePaneGetsShorterChunks() {
        let plan = RemoteTmuxPaneHistoryPlan(
            historySize: 300, paneWidth: 1_000, maximumCommandBlockBytes: Self.commandBlockBytes)
        // 131,072 cells per chunk at 1,000 columns is 131 rows.
        #expect(plan.chunks.map(\.end) == ["-170", "-39", "-1"])
        #expect(plan.chunks.first?.start == "-")
    }

    @Test func aSmallerBlockLimitGivesShorterChunks() {
        // Half the block limit: 65,536 cells, 65 rows at 1,000 columns.
        let plan = RemoteTmuxPaneHistoryPlan(
            historySize: 300, paneWidth: 1_000, maximumCommandBlockBytes: Self.commandBlockBytes / 2)
        #expect(plan.chunks.map(\.end) == ["-236", "-171", "-106", "-41", "-1"])
    }

    @Test func historyPastTheCapStartsAtTheCapAndSaysSo() {
        let plan = RemoteTmuxPaneHistoryPlan(
            historySize: 250_000, paneWidth: 100, maximumCommandBlockBytes: Self.commandBlockBytes)
        #expect(plan.historyRows == RemoteTmuxPaneHistoryPlan.maximumRows)
        #expect(plan.isTruncated)
        #expect(plan.chunks.first?.start == "-\(RemoteTmuxPaneHistoryPlan.maximumRows)")
        #expect(plan.chunks.last?.end == "-1")
    }

    @Test func aChunkOfTheDensestColorOutputFitsInOneCommandBlock() {
        // tmux 3.7 writes 55 bytes per cell from `capture-pane -e` when every cell
        // changes bold, italic, underline, strikethrough and its 24-bit foreground,
        // background and underline colors. The stream resets on a block over the
        // parser's limit, so a chunk of such cells must stay under it.
        let measuredBytesPerCell = 55
        for width in [80, 200, 500, 1_000, 10_000] {
            let historySize = 100_000
            let plan = RemoteTmuxPaneHistoryPlan(
                historySize: historySize, paneWidth: width, maximumCommandBlockBytes: Self.commandBlockBytes)
            for chunk in plan.chunks {
                let top = chunk.start == "-" ? historySize : -(Int(chunk.start) ?? 0)
                let bottom = -(Int(chunk.end) ?? 0)
                let bytes = (top - bottom + 1) * width * measuredBytesPerCell
                #expect(
                    bytes < Self.commandBlockBytes,
                    "width \(width): chunk \(chunk.captureArguments) can be \(bytes) bytes"
                )
            }
        }
    }

    @Test func aVeryWidePaneReadsTheNewestRowsThatFitTheChunkCapAndSaysSo() {
        // 131,072 cells per chunk at 10,000 columns is 13 rows, so 100,000 rows would
        // take 7,693 chunks: a command queue of about 360 KB, past the control client's
        // 256 KiB stdin budget.
        let plan = RemoteTmuxPaneHistoryPlan(
            historySize: 100_000, paneWidth: 10_000, maximumCommandBlockBytes: Self.commandBlockBytes)
        #expect(plan.chunks.count == 2_048)
        #expect(plan.historyRows == 2_048 * 13)
        #expect(plan.isTruncated)
        #expect(plan.chunks.first?.start == "-\(plan.historyRows)")
        #expect(plan.chunks.last?.end == "-1")
    }

    @Test func everyPlansChunkCommandsFitInHalfTheStdinBudget() {
        // The app sends every chunk in one queue, and its control client refuses a write
        // that would leave more than 256 KiB pending on tmux's stdin.
        let stdinBudget = 256 * 1_024
        for width in [80, 1_000, 5_000, 10_000] {
            let plan = RemoteTmuxPaneHistoryPlan(
                historySize: 100_000, paneWidth: width, maximumCommandBlockBytes: Self.commandBlockBytes)
            let bytes = plan.chunks
                .map { "capture-pane -p -e \($0.captureArguments) -t %99999\n".utf8.count }
                .reduce(0, +)
            #expect(bytes <= stdinBudget / 2, "width \(width): \(plan.chunks.count) chunks, \(bytes) bytes")
        }
    }

    @Test func aByteBudgetReadsOnlyTheNewestRowsItHolds() {
        // A 200-column row where every cell changes its 24-bit colors takes about 7,400
        // bytes; 12 MiB holds 1,700 of them, not the 100,000 tmux has.
        let budget = 12 * 1_024 * 1_024
        let plan = RemoteTmuxPaneHistoryPlan(
            historySize: 100_000, paneWidth: 200, maximumCommandBlockBytes: Self.commandBlockBytes,
            maximumBytes: budget, bytesPerRow: 7_400)
        #expect(plan.historyRows == budget / 7_400)
        #expect(plan.isTruncated)
        #expect(plan.chunks.first?.start == "-\(plan.historyRows)")
        #expect(plan.chunks.last?.end == "-1")
    }

    @Test func plainTextHistoryFitsTheByteBudgetWhole() {
        // 100,000 rows of 80-column text are about 8 MB, so the row cap binds first.
        let plan = RemoteTmuxPaneHistoryPlan(
            historySize: 100_000, paneWidth: 80, maximumCommandBlockBytes: Self.commandBlockBytes,
            maximumBytes: 12 * 1_024 * 1_024, bytesPerRow: 82)
        #expect(plan.historyRows == 100_000)
        #expect(!plan.isTruncated)
        #expect(plan.chunks.first?.start == "-")
    }

    @Test func theSampleOfTheDensestOutputStaysWithinItsBudget() {
        for width in [1, 80, 200, 1_000, 10_000, 100_000] {
            let rows = RemoteTmuxPaneHistoryPlan.sampleRows(historySize: 1_000_000, paneWidth: width)
            #expect(rows >= 1)
            #expect(rows <= RemoteTmuxPaneHistoryPlan.maximumSampleRows)
            // One row is always read, so only a pane wider than the budget can pass it.
            if width * RemoteTmuxPaneHistoryPlan.maximumEncodedBytesPerCell <= RemoteTmuxPaneHistoryPlan.maximumSampleBytes {
                #expect(rows * width * RemoteTmuxPaneHistoryPlan.maximumEncodedBytesPerCell
                    <= RemoteTmuxPaneHistoryPlan.maximumSampleBytes, "width \(width): \(rows) rows")
            }
        }
        #expect(RemoteTmuxPaneHistoryPlan.sampleRows(historySize: 3, paneWidth: 80) == 3)
        #expect(RemoteTmuxPaneHistoryPlan.sampleRows(historySize: 0, paneWidth: 80) == 0)
    }

    @Test func aSampledRowCountsItsLineEnding() {
        // The seed holds each row with a CR LF; the average rounds up.
        #expect(RemoteTmuxPaneHistoryPlan.bytesPerRow(sampledRows: ["abc", "", "abcd"]) == 5)
        #expect(RemoteTmuxPaneHistoryPlan.bytesPerRow(sampledRows: ["\u{1b}[31mé"]) == 9)
        #expect(RemoteTmuxPaneHistoryPlan.bytesPerRow(sampledRows: []) == nil)
    }

    @Test func aPaneWithNoHistoryNeedsNoChunk() {
        let plan = RemoteTmuxPaneHistoryPlan(
            historySize: 0, paneWidth: 80, maximumCommandBlockBytes: Self.commandBlockBytes)
        #expect(plan.chunks.isEmpty)
        #expect(plan.historyRows == 0)
    }
}
