@testable import CmuxNextApp
@testable import CmuxNextSidebar
import Foundation
import Testing

/// The sidebar snapshot file has one size limit (`SidebarSnapshotFile.maximumBytes`). The writer used to
/// write any size and the reader dropped a file over 2 MB, both silently: a sidebar past the limit came back
/// as placeholder rows on every launch with nothing in the log. Now the writer compacts to fit and reports
/// it, and the reader reports a file it refuses with its size and the limit.
@Suite
struct SidebarSnapshotSizeLimitTests {
    private nonisolated final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [SidebarSnapshotFile.Event] = []
        var all: [SidebarSnapshotFile.Event] { lock.withLock { stored } }
        func append(_ event: SidebarSnapshotFile.Event) { lock.withLock { stored.append(event) } }
    }

    private static func file(_ name: String, events: Events) -> SidebarSnapshotFile {
        let directory = FileManager.default.temporaryDirectory.appending(path: "sidebar-snapshot-limit-\(UUID().uuidString)")
        return SidebarSnapshotFile(url: directory.appending(path: name), report: { events.append($0) })
    }

    private static func text(_ prefix: String, _ index: Int, length: Int) -> String {
        let head = "\(prefix) \(index) "
        return head + String(repeating: "x", count: max(0, length - head.count))
    }

    /// A row with every saved detail filled, at lengths a busy agent row shows.
    private static func row(_ index: Int, titleLength: Int = 40) -> SidebarWorkspaceSnapshot {
        var ws = SidebarWorkspace(id: WorkspaceID("workspace-\(index)-\(UUID().uuidString)"), title: text("title", index, length: titleLength),
                                  directory: text("~/Projects/repo", index, length: 60), branch: text("lane/branch", index, length: 40),
                                  process: "claude", status: text("status", index, length: 80), ports: "3000, 5173",
                                  pullRequest: "#\(40000 + index)", lastActivity: Date(timeIntervalSince1970: 1_800_000_000),
                                  kind: .harness, kindBrand: "claude")
        ws.notificationText = text("notification", index, length: 120)
        ws.taskStatus = .done
        ws.reported = SidebarWorkspaceStatus(entries: (0 ..< 3).map { SidebarWorkspaceStatus.Entry(key: "key\($0)", text: text("entry", $0, length: 80)) },
                                             log: SidebarWorkspaceStatus.LogLine(level: .info, text: text("log", index, length: 120)),
                                             progressLabel: "step 3 of 7")
        return SidebarWorkspaceSnapshot(row: ws)
    }

    private static func snapshot(rows: Int, titleLength: Int = 40) -> SidebarSnapshot {
        let nodes = (0 ..< rows).map { SidebarSnapshot.Node(workspace: row($0, titleLength: titleLength), group: nil) }
        return SidebarSnapshot(sections: [SidebarSnapshot.Section(machineID: "local", machineName: "This Mac", machineKind: "local",
                                                                  isCollapsed: false, nodes: nodes)],
                               profiles: [], activeProfileID: nil)
    }

    private static func size(_ url: URL) throws -> Int {
        try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    }

    /// Leo's scale (about 1,600 workspaces in each of 4 windows, every row with its detail): over the limit
    /// as is. The file written is under it, the reader takes it, and the compaction is reported.
    @Test func aSnapshotOverTheLimitWritesAFileTheReaderAccepts() throws {
        var document = SidebarSnapshotDocument()
        for window in 0 ..< 4 { document.record(Self.snapshot(rows: 1_600), window: "window-\(window)") }
        let full = try JSONEncoder().encode(document).count
        #expect(full > SidebarSnapshotFile.maximumBytes)

        let events = Events()
        let file = Self.file("sidebar-snapshot-v1.json", events: events)
        try file.write(document)
        let written = try Self.size(file.url)
        print("sidebar snapshot at Leo's scale: \(full) bytes as is, \(written) bytes written, limit \(SidebarSnapshotFile.maximumBytes)")
        #expect(written <= SidebarSnapshotFile.maximumBytes)

        let read = try #require(file.read())
        #expect(read.windows.first?.windowID == document.windows.first?.windowID)
        #expect(read.windows.first?.snapshot.workspaceIDs == document.windows.first?.snapshot.workspaceIDs)
        guard case let .compacted(compaction)? = events.all.first else { Issue.record("no compaction reported: \(events.all)"); return }
        #expect(events.all.count == 1)
        #expect(compaction.bytesBefore == full && compaction.bytesAfter == written)
        #expect(compaction.droppedRowDetail)
        // Rows keep what places them; the second line and status block arrive live.
        let first = try #require(read.windows.first?.snapshot.sections.first?.nodes.first?.workspace)
        #expect(first.title.hasPrefix("title 0") && first.taskStatus == "done" && first.directory == nil && first.status == nil)
    }

    /// When even rows without detail do not fit in one window, the bottom rows go and the top ones,
    /// which the first frame shows, stay in order.
    @Test func aSidebarTooLongEvenWithoutDetailKeepsItsTopRows() throws {
        var document = SidebarSnapshotDocument()
        document.record(Self.snapshot(rows: 12_000, titleLength: 200), window: "only")
        let events = Events()
        let file = Self.file("sidebar-snapshot-v1.json", events: events)
        try file.write(document)
        #expect(try Self.size(file.url) <= SidebarSnapshotFile.maximumBytes)
        let read = try #require(file.read())
        let ids = try #require(read.windows.first?.snapshot.workspaceIDs)
        #expect(!ids.isEmpty && ids.count < 12_000)
        #expect(ids == Array(document.windows[0].snapshot.workspaceIDs.prefix(ids.count)))
        guard case let .compacted(compaction)? = events.all.first else { Issue.record("no compaction reported"); return }
        #expect(compaction.droppedRows == 12_000 - ids.count)
    }

    /// A file over the limit on disk (written by an older build) is refused with its size and the limit.
    @Test func aFileOverTheLimitOnDiskIsReportedWithItsSizeAndTheLimit() throws {
        let events = Events()
        let file = Self.file("sidebar-snapshot-v1.json", events: events)
        try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = SidebarSnapshotFile.maximumBytes + 1
        try Data(repeating: 0x20, count: bytes).write(to: file.url)
        #expect(file.read() == nil)
        #expect(events.all == [.skipped(.tooLarge(bytes: bytes, limit: SidebarSnapshotFile.maximumBytes))])
    }

    /// A small sidebar is written whole, read back the same, and nothing is reported; a missing file is a
    /// first launch and is not reported either.
    @Test func aSnapshotUnderTheLimitIsWrittenWholeAndQuietly() throws {
        let events = Events()
        let file = Self.file("sidebar-snapshot-v1.json", events: events)
        #expect(file.read() == nil)
        var document = SidebarSnapshotDocument()
        document.record(Self.snapshot(rows: 90), window: "a")
        try file.write(document)
        #expect(file.read() == document)
        #expect(events.all.isEmpty)
    }
}
