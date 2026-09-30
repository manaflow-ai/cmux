import Foundation
import Testing
@testable import CmuxFileTree

/// Synthetic 50,000-entry benchmarks for the file tree hot paths.
///
/// Numbers print to the test log for the PR record. The limits are an order of
/// magnitude above measured values on an M-series Mac so the suite stays
/// stable on loaded CI hosts while still failing on a quadratic regression
/// (the pre-rewrite tree took over 90 s to expand 4,000 children).
@Suite(.serialized) struct FileTreePerformanceBenchmarkTests {
    private static let entryCount = 50_000

    private static func syntheticEntries(parent: String = "/bench") -> [FileTreeEntry] {
        (0..<entryCount).map { index in
            let isDirectory = index % 10 == 0
            let name = isDirectory ? "pkg-\(index)" : "file-\(index).js"
            return FileTreeEntry(
                name: name,
                path: parent + "/" + name,
                kind: isDirectory ? .directory : .file,
                size: Int64(index),
                modificationTime: TimeInterval(index)
            )
        }.shuffled(using: &benchmarkGenerator)
    }

    nonisolated(unsafe) private static var benchmarkGenerator = SeededGenerator(seed: 50_000)

    private static func measure(_ label: String, _ body: () -> Void) -> Duration {
        let clock = ContinuousClock()
        let elapsed = clock.measure(body)
        print("[file-tree-bench] \(label): \(elapsed.formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 1))))")
        return elapsed
    }

    @Test func sortDiffAndPresentationOnFiftyThousandEntries() async {
        let entries = Self.syntheticEntries()
        var sorted: [FileTreeEntry] = []
        let sortTime = Self.measure("sort 50k by name") {
            sorted = FileTreeSortOrder.standard.sorted(entries)
        }
        #expect(sorted.count == Self.entryCount)
        #expect(sortTime < .seconds(3))

        let initialDiffTime = Self.measure("initial diff 50k") {
            _ = FileTreeChildrenDiff(old: [], new: sorted)
        }
        #expect(initialDiffTime < .seconds(1))

        var changed = sorted
        changed.remove(at: 25_000)
        changed.insert(FileTreeEntry(name: "file-new.js", path: "/bench/file-new.js", kind: .file), at: 40_000)
        var diff = FileTreeChildrenDiff.empty
        let churnDiffTime = Self.measure("one-file churn diff 50k") {
            diff = FileTreeChildrenDiff(old: sorted, new: changed)
        }
        #expect(diff.structuralChangeCount == 2)
        #expect(churnDiffTime < .seconds(2))

        let resorted = FileTreeSortOrder(key: .size, ascending: false).sorted(entries)
        let reorderTime = Self.measure("full reorder diff 50k") {
            _ = FileTreeChildrenDiff(old: sorted, new: resorted)
        }
        #expect(reorderTime < .seconds(3))
    }

    @Test func listAndLoadAFiftyThousandEntryDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-file-tree-bench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<Self.entryCount {
            let fd = open(root.path + "/file-\(index).js", O_CREAT | O_WRONLY, 0o644)
            if fd >= 0 { close(fd) }
        }

        let provider = LocalFileTreeProvider()
        let clock = ContinuousClock()
        var listing = FileTreeListing(entries: [])
        let listTime = try await clock.measure {
            listing = try await provider.listDirectory(at: root.path)
        }
        print("[file-tree-bench] getattrlistbulk list 50k: \(listTime)")
        #expect(listing.entries.count == Self.entryCount)
        #expect(listTime < .seconds(5))

        let engine = FileTreeEngine(provider: provider)
        var updates: [FileTreeDirectoryUpdate] = []
        let loadTime = await clock.measure {
            updates = await engine.load([root.path])
        }
        print("[file-tree-bench] engine load (list+sort+diff) 50k: \(loadTime)")
        #expect(loadTime < .seconds(8))

        // A single new file refreshes the directory with a one-row diff.
        let fd = open(root.path + "/zz-new.js", O_CREAT | O_WRONLY, 0o644)
        if fd >= 0 { close(fd) }
        var refresh: [FileTreeDirectoryUpdate] = []
        let refreshTime = await clock.measure {
            refresh = await engine.load([root.path])
        }
        print("[file-tree-bench] engine refresh after one new file 50k: \(refreshTime)")
        guard case .loaded(_, let diff, _)? = refresh.first?.outcome else {
            Issue.record("expected a loaded refresh")
            return
        }
        #expect(diff.inserted.count == 1)
        #expect(diff.removed.isEmpty)
        #expect(updates.count == 1)
        #expect(refreshTime < .seconds(8))
    }
}
