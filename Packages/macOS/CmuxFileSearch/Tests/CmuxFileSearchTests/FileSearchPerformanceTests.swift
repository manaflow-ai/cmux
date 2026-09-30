import Foundation
import Testing

@testable import CmuxFileSearch

/// 100,000 matches through the off-main decoder and the main-thread tree.
/// The numbers print so the PR can quote them; the bounds are loose enough
/// for a loaded CI runner and still catch an accidental quadratic path.
@Suite("100k-match throughput", .serialized)
struct FileSearchPerformanceTests {
    static let fileCount = 2_000
    static let matchesPerFile = 50

    static let output: Data = {
        var text = ""
        text.reserveCapacity(fileCount * matchesPerFile * 260)
        let line = "        let value = computeSomething(needle, other: needle) // trailing comment text\n"
        for file in 0..<fileCount {
            let path = "/workspace/project/Sources/Module\(file % 40)/File\(file).swift"
            text += #"{"type":"begin","data":{"path":{"text":"\#(path)"}}}"# + "\n"
            for index in 0..<(matchesPerFile / 2) {
                // Two submatches per line: 25 lines x 2 = 50 matches per file.
                text += RipgrepFixture.matchLine(path: path, line: line, lineNumber: index + 1, byteRanges: [35..<41, 50..<56]) + "\n"
            }
            text += #"{"type":"end","data":{"path":{"text":"\#(path)"}}}"# + "\n"
        }
        return Data(text.utf8)
    }()

    @Test("Decoding 100k matches in 64 KiB chunks")
    func decode() {
        let data = Self.output
        let clock = ContinuousClock()
        var groups: [FileSearchFileMatches] = []
        let decoder = RipgrepStreamDecoder(matchLimit: 1_000_000)
        let elapsed = clock.measure {
            var offset = 0
            while offset < data.count {
                let end = min(offset + 64 * 1024, data.count)
                groups.appendMerging(decoder.consume(data[offset..<end]))
                offset = end
            }
            groups.appendMerging(decoder.finish())
        }
        print("PERF decode matches=\(decoder.matchCount) bytes=\(data.count) ms=\(Self.milliseconds(elapsed))")
        #expect(decoder.matchCount == Self.fileCount * Self.matchesPerFile)
        #expect(groups.count == Self.fileCount)
        #expect(elapsed < .seconds(10))
    }

    @Test("Applying 100k matches to the tree in per-frame batches")
    func treeApply() {
        let decoder = RipgrepStreamDecoder(matchLimit: 1_000_000)
        var batches: [[FileSearchFileMatches]] = []
        let data = Self.output
        var offset = 0
        while offset < data.count {
            let end = min(offset + 64 * 1024, data.count)
            batches.append(decoder.consume(data[offset..<end]))
            offset = end
        }
        let tree = FileSearchResultTree { String($0.dropFirst("/workspace/project/".count)) }
        let clock = ContinuousClock()
        var slowest = Duration.zero
        let total = clock.measure {
            for batch in batches {
                let one = clock.measure { tree.apply(batch) }
                slowest = max(slowest, one)
            }
            // Materialize every row object, as an outline with all files
            // expanded does.
            for file in tree.files {
                for index in file.matches.indices { _ = file.matchNode(at: index) }
            }
        }
        print(
            "PERF tree matches=\(tree.matchCount) files=\(tree.fileCount) batches=\(batches.count) " +
                "totalMs=\(Self.milliseconds(total)) slowestBatchMs=\(Self.milliseconds(slowest))"
        )
        #expect(tree.matchCount == 100_000)
        #expect(slowest < .milliseconds(250))
    }

    @Test("Navigating next across 100k matches stays constant time per step")
    func navigation() {
        let tree = FileSearchResultTree { $0 }
        tree.apply(RipgrepStreamDecoder(matchLimit: 1_000_000).consume(Self.output))
        let clock = ContinuousClock()
        var position: FileSearchResultPosition?
        let elapsed = clock.measure {
            for _ in 0..<100_000 { position = tree.nextMatch(after: position) }
        }
        print("PERF navigate steps=100000 ms=\(Self.milliseconds(elapsed))")
        #expect(position == FileSearchResultPosition(fileIndex: Self.fileCount - 1, matchIndex: Self.matchesPerFile - 1))
    }

    static func milliseconds(_ duration: Duration) -> String {
        let components = duration.components
        let value = Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
        return String(format: "%.1f", value)
    }
}
