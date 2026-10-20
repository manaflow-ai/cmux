import Foundation
import Testing
@testable import CMUXAgentLaunch

/// Launch reads of the Feed log. `WorkstreamStore.start()` runs these on every
/// app launch, and the log is append-only and shared by every cmux build, so
/// their memory must not grow with the file (a 3.5 GB log reached a 3.6 GB
/// footprint seconds after launch).
@Suite("WorkstreamPersistence bounded launch load", .serialized)
struct WorkstreamPersistenceBoundedLoadTests {
    @Test("Launch loads read only the newest rows of a huge log")
    func launchLoadsStayBoundedOnHugeLog() async throws {
        let log = try Self.makeLog()
        defer { try? FileManager.default.removeItem(at: log) }
        // A sparse, newline-free region stands in for years of history. It
        // costs no disk space, but reading it costs its full size.
        let prefixBytes: UInt64 = 256 * 1024 * 1024
        try Self.extend(log, to: prefixBytes)
        let items = (0..<8).map { Self.item("s\($0)") }
        for item in items { try Self.appendRow(item, to: log) }
        let persistence = WorkstreamPersistence(fileURL: log)

        let revision = try await persistence.loadRevision()
        let latest = try await persistence.loadLatest(limit: items.count)
        let latestBytesRead = await persistence.lastLoadBytesRead
        let page = try await persistence.loadPage(limit: 5)
        let pageBytesRead = await persistence.lastLoadBytesRead

        #expect(latest.map(\.id) == items.map(\.id))
        #expect(page.items.map(\.id) == items.suffix(5).map(\.id))
        #expect(revision >= items.count)
        // Counting bytes read, not the process footprint, keeps this exact
        // while other suites allocate in parallel.
        let budget: UInt64 = 1024 * 1024
        #expect(latestBytesRead < budget, "loadLatest read \(latestBytesRead) bytes of a \(prefixBytes / 1_048_576) MiB log")
        #expect(pageBytesRead < budget, "loadPage read \(pageBytesRead) bytes of a \(prefixBytes / 1_048_576) MiB log")
    }

    @Test("A newline-free region larger than any row is skipped, not buffered")
    func oversizedRegionIsSkipped() async throws {
        let log = try Self.makeLog()
        defer { try? FileManager.default.removeItem(at: log) }
        let older = Self.item("older")
        try Self.appendRow(older, to: log)
        let size = try FileManager.default.attributesOfItem(atPath: log.path)[.size] as? NSNumber
        try Self.extend(log, to: (size?.uint64Value ?? 0) + 4 * 1024 * 1024)
        let newer = Self.item("newer")
        try Self.appendRow(newer, to: log)
        let handle = try FileHandle(forReadingFrom: log)
        defer { try? handle.close() }
        var reader = WorkstreamLogBackwardReader(
            handle: handle,
            endOffset: try handle.seekToEnd(),
            maximumRowBytes: 64 * 1024
        )

        var decoded: [UUID] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        while let row = try reader.next() {
            if let item = try? decoder.decode(WorkstreamItem.self, from: row.bytes) {
                decoded.append(item.id)
            }
        }
        #expect(decoded == [newer.id, older.id])
    }

    @Test("Latest load keeps each item's newest version in newest-row order")
    func latestLoadCollapsesMutationRows() async throws {
        let log = try Self.makeLog()
        defer { try? FileManager.default.removeItem(at: log) }
        let first = Self.item("first")
        let second = Self.item("second")
        let third = Self.item("third")
        var resolvedFirst = first
        resolvedFirst.status = .resolved(.permission(.once), at: Date(timeIntervalSince1970: 1_000))
        for row in [first, second, third, resolvedFirst] { try Self.appendRow(row, to: log) }
        try Data("not json\n\n".utf8).appendingToFile(at: log)
        let persistence = WorkstreamPersistence(fileURL: log)

        let latest = try await persistence.loadLatest(limit: 10)
        #expect(latest.map(\.id) == [second.id, third.id, first.id])
        #expect(latest.last?.status == resolvedFirst.status)

        let newestTwo = try await persistence.loadLatest(limit: 2)
        #expect(newestTwo.map(\.id) == [third.id, first.id])
    }

    @Test("Revision never falls below the persisted row count and grows with appends")
    func revisionTracksAppends() async throws {
        let log = try Self.makeLog()
        defer { try? FileManager.default.removeItem(at: log) }
        let persistence = WorkstreamPersistence(fileURL: log)
        #expect(try await persistence.loadRevision() == 0)

        var previous = 0
        for index in 1...5 {
            try await persistence.append(Self.item("s\(index)"))
            let revision = try await persistence.loadRevision()
            #expect(revision >= index)
            #expect(revision > previous)
            previous = revision
        }
    }

    private static func makeLog() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-bounded-\(UUID().uuidString).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return url
    }

    private static func extend(_ url: URL, to size: UInt64) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: size)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x0A]))
    }

    private static func appendRow(_ item: WorkstreamItem, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var row = try encoder.encode(item)
        row.append(0x0A)
        try row.appendingToFile(at: url)
    }

    private static func item(_ workstreamId: String) -> WorkstreamItem {
        WorkstreamItem(
            workstreamId: workstreamId,
            source: .claude,
            kind: .permissionRequest,
            payload: .permissionRequest(requestId: workstreamId, toolName: "Write", toolInputJSON: "{}", pattern: nil)
        )
    }
}

private extension Data {
    func appendingToFile(at url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: self)
    }
}
