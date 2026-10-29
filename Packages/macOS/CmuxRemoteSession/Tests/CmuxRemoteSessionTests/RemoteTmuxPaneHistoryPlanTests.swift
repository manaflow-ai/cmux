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

    @Test func aPaneWithNoHistoryNeedsNoChunk() {
        let plan = RemoteTmuxPaneHistoryPlan(
            historySize: 0, paneWidth: 80, maximumCommandBlockBytes: Self.commandBlockBytes)
        #expect(plan.chunks.isEmpty)
        #expect(plan.historyRows == 0)
    }
}
