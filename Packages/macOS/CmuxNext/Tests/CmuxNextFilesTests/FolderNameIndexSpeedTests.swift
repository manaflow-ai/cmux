import Foundation
import Testing
@testable import CmuxNextFiles

/// The Files pane's name search stays fast at Finder-folder sizes: 100 000 files, 100 folders
/// (plans/cmux-next/files-finder-parity-DESIGN.md, 4.3). The bounds are loose ceilings for a busy
/// test host, far above the measured times; the printed lines are the numbers for BENCH.
@Suite(.serialized) struct FolderNameIndexSpeedTests {
    private static func corpus(_ count: Int) throws -> TempFolder {
        let temp = try TempFolder()
        let kinds = ["report-%d.txt", "IMG_%05d.jpg", "notes %d.md", "invoice_%d.pdf", "build-log-%d.log",
                     "component%d.tsx", "Screenshot %d.png", "draft %d.docx", "data-%d.json", "song %d.mp3"]
        let fm = FileManager.default
        for dir in 0..<(count / 1000) {
            let folder = temp.url.appendingPathComponent(String(format: "dir%03d", dir), isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            for i in (dir * 1000)..<((dir + 1) * 1000) {
                let name = i % 9973 == 0 ? "needle-quasar-\(i).txt" : String(format: kinds[i % kinds.count], i)
                guard fm.createFile(atPath: folder.appendingPathComponent(name).path, contents: nil) else {
                    throw FileBrowserError.failed("create \(name)")
                }
            }
        }
        return temp
    }

    private static func ms(_ body: () throws -> Void) rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private static func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

    @Test func searchesAHundredThousandNamesWithinAFrame() throws {
        let temp = try Self.corpus(100_000)
        var index: FolderNameIndex?
        let build = try (0..<3).map { _ in try Self.ms { index = try FolderNameIndex.build(root: temp.url) } }
        let built = try #require(index)
        #expect(built.count == 100_100)
        print("FILES-BENCH index items=\(built.count) build_median_ms=\(String(format: "%.1f", Self.median(build)))")
        for (query, expected) in [("quasar", 11), ("screenshot", 200), ("report", 200)] {
            var hits = 0
            let times = (0..<25).map { _ in Self.ms { hits = built.search(query).count } }
            let median = Self.median(times)
            print("FILES-BENCH search q=\(query) hits=\(hits) median_ms=\(String(format: "%.3f", median))")
            #expect(hits == expected)
            // One 120 Hz frame is 8 ms; a loaded test host gets twice that.
            #expect(median < 16, "search \(query): \(median) ms")
        }
        #expect(Self.median(build) < 3000, "index build: \(Self.median(build)) ms")
    }
}
