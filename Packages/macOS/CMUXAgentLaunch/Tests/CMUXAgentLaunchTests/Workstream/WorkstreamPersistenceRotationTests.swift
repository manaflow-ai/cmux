import Foundation
import Testing
@testable import CMUXAgentLaunch
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite("WorkstreamPersistence rotation")
struct WorkstreamPersistenceRotationTests {
    @Test("append past the cap rotates to exactly one previous generation")
    func appendRotatesToOneGeneration() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let active = dir.appendingPathComponent("workstream.jsonl")
        let previous = dir.appendingPathComponent("workstream.1.jsonl")
        let cap: UInt64 = 2_048
        let persistence = WorkstreamPersistence(fileURL: active, maxActiveFileBytes: cap)

        for i in 0..<60 {
            try await persistence.append(makeItem(i))
        }

        #expect(FileManager.default.fileExists(atPath: previous.path))
        #expect(try fileSize(active) <= cap)
        #expect(try fileSize(previous) <= cap)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(names == ["workstream.1.jsonl", "workstream.jsonl"])
    }

    @Test("paging walks from the active file into the previous generation")
    func pagingCrossesRotationBoundary() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let active = dir.appendingPathComponent("workstream.jsonl")
        let persistence = WorkstreamPersistence(fileURL: active, maxActiveFileBytes: 2_048)
        for i in 0..<60 {
            try await persistence.append(makeItem(i))
        }
        let activeLineCount = try lineCount(active)

        var collected: [String] = []
        var page = try await persistence.loadPage(limit: 3)
        collected.insert(contentsOf: page.items.map(\.workstreamId), at: 0)
        var guardCount = 0
        while page.hasMoreBefore, let cursor = page.startCursor, guardCount < 100 {
            page = try await persistence.loadPage(endingBefore: cursor, limit: 3)
            collected.insert(contentsOf: page.items.map(\.workstreamId), at: 0)
            guardCount += 1
        }

        #expect(collected.count > activeLineCount)
        #expect(collected.last == "s59")
        let firstIndex = try #require(collected.first.flatMap { Int($0.dropFirst()) })
        #expect(collected == (firstIndex..<60).map { "s\($0)" })
    }

    @Test("a cursor taken before a rotation still pages the rows before it")
    func cursorSurvivesRotation() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let active = dir.appendingPathComponent("workstream.jsonl")
        let persistence = WorkstreamPersistence(fileURL: active, maxActiveFileBytes: 4_096)
        for i in 0..<5 {
            try await persistence.append(makeItem(i))
        }
        let newest = try await persistence.loadPage(limit: 2)
        #expect(newest.items.map(\.workstreamId) == ["s3", "s4"])
        let cursor = try #require(newest.startCursor)

        let rotated = dir.appendingPathComponent("workstream.1.jsonl")
        var next = 5
        while !FileManager.default.fileExists(atPath: rotated.path) {
            try await persistence.append(makeItem(next))
            next += 1
            try #require(next < 500)
        }

        let older = try await persistence.loadPage(endingBefore: cursor, limit: 2)
        #expect(older.items.map(\.workstreamId) == ["s1", "s2"])
        #expect(older.hasMoreBefore)
    }

    @Test("legacy bare-offset cursors still decode")
    func legacyCursorDecodes() throws {
        let decoded = try JSONDecoder().decode(
            WorkstreamPersistence.Cursor.self,
            from: Data("1234".utf8)
        )
        #expect(decoded.offset == 1_234)
        let roundTrip = try JSONDecoder().decode(
            WorkstreamPersistence.Cursor.self,
            from: JSONEncoder().encode(decoded)
        )
        #expect(roundTrip == decoded)
    }

    @Test("append after another process unlinks the file creates a new file")
    func appendAfterUnlinkCreatesNewFile() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let active = dir.appendingPathComponent("workstream.jsonl")
        let persistence = WorkstreamPersistence(fileURL: active)
        try await persistence.append(makeItem(0))
        let firstInode = try inode(active)

        // Same operation `cmux feed clear` performs from the CLI process.
        try FileManager.default.removeItem(at: active)
        try await persistence.append(makeItem(1))

        #expect(FileManager.default.fileExists(atPath: active.path))
        #expect(try inode(active) != firstInode)
        let loaded = try await persistence.loadRecent(limit: 10)
        #expect(loaded.map(\.workstreamId) == ["s1"])
    }

    @Test("an oversized legacy file is trimmed to its newest bytes on a line boundary")
    func oversizedLegacyFileIsTrimmed() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let active = dir.appendingPathComponent("workstream.jsonl")
        let cap: UInt64 = 4_096

        // Build the legacy file with an uncapped writer, varying line
        // lengths so the byte cut lands inside a line.
        let legacyWriter = WorkstreamPersistence(fileURL: active)
        for i in 0..<120 {
            try await legacyWriter.append(makeItem(i, padding: i % 7))
        }
        let original = try Data(contentsOf: active)
        #expect(UInt64(original.count) > cap * 4)

        let persistence = WorkstreamPersistence(fileURL: active, maxActiveFileBytes: cap)
        // The first read answers from the untrimmed file without waiting.
        let recent = try await persistence.loadRecent(limit: 1)
        #expect(recent.map(\.workstreamId) == ["s119"])
        await persistence.waitForLegacyTrim()

        let trimmed = try Data(contentsOf: active)
        #expect(!trimmed.isEmpty)
        #expect(UInt64(trimmed.count) <= cap)
        // The kept bytes are the file's exact suffix and begin right after
        // a newline in the original, so no partial line survives.
        #expect(original.suffix(trimmed.count) == trimmed)
        let cut = original.count - trimmed.count
        #expect(original[original.startIndex + cut - 1] == 0x0A)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for line in trimmed.split(separator: 0x0A) {
            #expect((try? decoder.decode(WorkstreamItem.self, from: Data(line))) != nil)
        }
        #expect(!FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("workstream.1.jsonl").path
        ))
    }

    @Test("cursors taken before the legacy trim re-anchor into the trimmed file")
    func cursorsReanchorAfterLegacyTrim() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let active = dir.appendingPathComponent("workstream.jsonl")
        let cap: UInt64 = 4_096
        let legacyWriter = WorkstreamPersistence(fileURL: active)
        for i in 0..<120 {
            try await legacyWriter.append(makeItem(i, padding: i % 7))
        }

        let release = AsyncStream<Void>.makeStream()
        let persistence = WorkstreamPersistence(fileURL: active, maxActiveFileBytes: cap)
        // Hold the trim's swap until both cursors come from the old file.
        await persistence.setLegacyTrimFinalizeGateForTesting {
            var iterator = release.stream.makeAsyncIterator()
            _ = await iterator.next()
        }
        let newest = try await persistence.loadPage(limit: 2)
        #expect(newest.items.map(\.workstreamId) == ["s118", "s119"])
        let recentCursor = try #require(newest.startCursor)
        // Far enough back that its rows fall before the kept range.
        let deep = try await persistence.loadPage(limit: 100)
        #expect(deep.items.first?.workstreamId == "s20")
        let deepCursor = try #require(deep.startCursor)

        release.continuation.yield()
        await persistence.waitForLegacyTrim()
        #expect(try fileSize(active) <= cap)

        let older = try await persistence.loadPage(endingBefore: recentCursor, limit: 2)
        #expect(older.items.map(\.workstreamId) == ["s116", "s117"])
        #expect(older.hasMoreBefore)

        var collected = older.items.map(\.workstreamId)
        var page = older
        var guardCount = 0
        while page.hasMoreBefore, let cursor = page.startCursor, guardCount < 100 {
            page = try await persistence.loadPage(endingBefore: cursor, limit: 5)
            collected.insert(contentsOf: page.items.map(\.workstreamId), at: 0)
            guardCount += 1
        }
        let firstIndex = try #require(collected.first.flatMap { Int($0.dropFirst()) })
        #expect(firstIndex > 20)
        #expect(collected == (firstIndex..<118).map { "s\($0)" })

        let beforeKept = try await persistence.loadPage(endingBefore: deepCursor, limit: 5)
        #expect(beforeKept.items.isEmpty)
        #expect(!beforeKept.hasMoreBefore)
    }

    @Test("appends made while the legacy trim copies are kept")
    func appendsDuringLegacyTrimAreKept() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let active = dir.appendingPathComponent("workstream.jsonl")
        let cap: UInt64 = 4_096
        let legacyWriter = WorkstreamPersistence(fileURL: active)
        for i in 0..<120 {
            try await legacyWriter.append(makeItem(i, padding: i % 7))
        }

        let copied = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let persistence = WorkstreamPersistence(fileURL: active, maxActiveFileBytes: cap)
        await persistence.setLegacyTrimFinalizeGateForTesting {
            copied.continuation.yield()
            var iterator = release.stream.makeAsyncIterator()
            _ = await iterator.next()
        }

        let recent = try await persistence.loadRecent(limit: 1)
        #expect(recent.map(\.workstreamId) == ["s119"])
        var copiedIterator = copied.stream.makeAsyncIterator()
        _ = await copiedIterator.next()

        // The copy snapshot is taken; these land after it.
        for i in 120..<123 {
            try await persistence.append(makeItem(i))
        }
        release.continuation.yield()
        await persistence.waitForLegacyTrim()

        // The trimmed file holds the kept tail plus the three appends, and
        // the oversized original was not rotated whole into `.1`.
        #expect(!FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("workstream.1.jsonl").path
        ))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let lines = try Data(contentsOf: active).split(separator: 0x0A)
        let ids = lines.compactMap {
            try? decoder.decode(WorkstreamItem.self, from: Data($0)).workstreamId
        }
        #expect(ids.count == lines.count)
        #expect(lines.count < 40)
        #expect(Array(ids.suffix(4)) == ["s119", "s120", "s121", "s122"])

        try await persistence.append(makeItem(123))
        let loaded = try await persistence.loadRecent(limit: 5)
        #expect(loaded.map(\.workstreamId) == ["s119", "s120", "s121", "s122", "s123"])
    }

    // MARK: - Helpers

    private func makeItem(_ index: Int, padding: Int = 0) -> WorkstreamItem {
        WorkstreamItem(
            workstreamId: "s\(index)",
            source: .claude,
            kind: .permissionRequest,
            payload: .permissionRequest(
                requestId: "r\(index)",
                toolName: "t",
                toolInputJSON: #"{"note":""# + String(repeating: "x", count: padding * 13) + #""}"#,
                pattern: nil
            )
        )
    }

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-rotation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func fileSize(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private func lineCount(_ url: URL) throws -> Int {
        try Data(contentsOf: url).split(separator: 0x0A).count
    }

    private func inode(_ url: URL) throws -> UInt64 {
        var info = stat()
        guard stat(url.path, &info) == 0 else {
            throw CocoaError(.fileNoSuchFile)
        }
        return UInt64(info.st_ino)
    }
}
