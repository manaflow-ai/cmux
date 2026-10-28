@testable import CmuxNextDiff
import CmuxNextWakeups
import Foundation
import Testing

/// A lane refuses a read once quit began (`BackgroundWork.beginShutdown`). The diff page's stores read their
/// file before each change; a refused read is not an empty file, so the change is dropped and the file keeps
/// every other entry (p02-threads 047-052 review). Before, the refusal read as `[]` and the next mark wrote
/// only itself over the whole file, with quit waiting for that write.
@Suite(.timeLimit(.minutes(1))) struct DiffStoresRefusedReadTests {
    @Test func aRefusedReadNeverReplacesTheViewedMarks() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-diff-refused-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(DiffViewedFiles.fileName)
        let kept = [DiffViewedFiles.Scope(key: "repo\nworking", changedAt: 1, files: [.init(path: "a.swift", fingerprint: "1")]),
                    DiffViewedFiles.Scope(key: "other\nworking", changedAt: 2, files: [.init(path: "b.swift", fingerprint: "2")])]
        let before = try JSONEncoder().encode(kept)
        try before.write(to: url)
        let work = BackgroundWork(label: "test.diff-refused")
        work.beginShutdown()

        let viewed = DiffViewedFiles(url: url, runner: work)
        await viewed.set(.init(path: "c.swift", fingerprint: "3"), in: "repo\nworking")
        await viewed.flush()

        #expect(try Data(contentsOf: url) == before)
    }

    @Test func aRefusedReadNeverReplacesTheCollapsedFiles() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-diff-refused-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(DiffCollapsedFiles.fileName)
        let before = try JSONEncoder().encode(["repo\u{0}a.swift", "repo\u{0}b.swift"])
        try before.write(to: url)
        let work = BackgroundWork(label: "test.diff-refused")
        work.beginShutdown()

        let collapsed = DiffCollapsedFiles(url: url, runner: work)
        #expect(await collapsed.list().isEmpty)
        await collapsed.set(["repo\u{0}c.swift"])
        await collapsed.flush()

        #expect(try Data(contentsOf: url) == before)
    }
}
