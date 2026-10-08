import Darwin
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

        let sampler = FootprintSampler()
        sampler.start()
        let revision = try await persistence.loadRevision()
        let latest = try await persistence.loadLatest(limit: 50)
        let page = try await persistence.loadPage(limit: 5)
        let peakGrowth = sampler.stop()

        #expect(latest.map(\.id) == items.map(\.id))
        #expect(page.items.map(\.id) == items.suffix(5).map(\.id))
        #expect(revision >= items.count)
        #expect(
            peakGrowth < 64 * 1024 * 1024,
            "Launch loads grew the footprint by \(peakGrowth / 1_048_576) MiB for a \(prefixBytes / 1_048_576) MiB log"
        )
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

/// Tracks the peak physical footprint while the code under test runs.
private final class FootprintSampler: @unchecked Sendable {
    private let queue = DispatchQueue(label: "cmux.tests.footprint-sampler")
    private var timer: DispatchSourceTimer?
    private var baseline: UInt64 = 0
    private var peak: UInt64 = 0

    func start() {
        baseline = Self.physicalFootprint()
        peak = baseline
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .microseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.peak = max(self.peak, Self.physicalFootprint())
        }
        self.timer = timer
        timer.resume()
    }

    /// Stops sampling and returns the peak growth over the starting footprint.
    func stop() -> UInt64 {
        queue.sync {
            timer?.cancel()
            timer = nil
            peak = max(peak, Self.physicalFootprint())
            return peak > baseline ? peak - baseline : 0
        }
    }

    private static func physicalFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
