import Foundation
import Testing

@testable import CmuxGit

@Suite struct WorkspaceChangesBaseCacheTests {
    @Test func zeroByteEntriesRemainBoundedByCount() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-base-cache-count-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = WorkspaceChangesBaseContentCache(
            byteBudget: 1_024,
            maximumEntryCount: 3,
            temporaryDirectory: root
        )

        var urls: [URL] = []
        for index in 0..<6 {
            let key = WorkspaceChangesBaseContentCache.Key(
                repoRoot: "/repo",
                baseCommitOID: "abc",
                path: "empty-\(index)"
            )
            let url = try await cache.withLeasedFileURL(
                for: key,
                projectedSize: 0,
                materialize: { destination in
                    try Data().write(to: destination)
                },
                operation: { $0 }
            )
            urls.append(url)
        }

        let survivors = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        #expect(survivors.count == 3)
        #expect(survivors == Array(urls.suffix(3)))
    }

    @Test func oversizedEntriesRejectAndLeastRecentlyUsedEntriesEvict() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-base-cache-budget-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = WorkspaceChangesBaseContentCache(byteBudget: 4, temporaryDirectory: root)
        let oversized = WorkspaceChangesBaseContentCache.Key(
            repoRoot: "/repo",
            baseCommitOID: "abc",
            path: "oversized"
        )

        await #expect(throws: WorkspaceChangesBaseContentCache.Error.entryExceedsByteBudget) {
            try await cache.withLeasedFileURL(
                for: oversized,
                projectedSize: 5,
                materialize: { destination in
                    try Data("12345".utf8).write(to: destination)
                },
                operation: { $0 }
            )
        }
        let recovered = try await cache.withLeasedFileURL(
            for: oversized,
            projectedSize: 1,
            materialize: { destination in
                try Data("x".utf8).write(to: destination)
            },
            operation: { $0 }
        )
        #expect(try Data(contentsOf: recovered) == Data("x".utf8))

        let second = WorkspaceChangesBaseContentCache.Key(
            repoRoot: "/repo",
            baseCommitOID: "abc",
            path: "second"
        )
        let third = WorkspaceChangesBaseContentCache.Key(
            repoRoot: "/repo",
            baseCommitOID: "abc",
            path: "third"
        )
        let secondURL = try await cache.withLeasedFileURL(
            for: second,
            projectedSize: 2,
            materialize: { destination in
                try Data("22".utf8).write(to: destination)
            },
            operation: { $0 }
        )
        _ = try await cache.withLeasedFileURL(
            for: third,
            projectedSize: 3,
            materialize: { destination in
                try Data("333".utf8).write(to: destination)
            },
            operation: { $0 }
        )
        #expect(!FileManager.default.fileExists(atPath: recovered.path))
        #expect(!FileManager.default.fileExists(atPath: secondURL.path))
    }
}
