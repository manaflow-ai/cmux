import Darwin
import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite
struct CodexResumePermissionEvidenceReaderTests {
    private let cutoff: TimeInterval = 1_800_000_000
    private let expected = ["-a", "never", "-s", "workspace-write", "-c", "sandbox_workspace_write.network_access=true"]

    /// Builds a permission record with a controlled year for capture-cutoff tests.
    private func record(year: Int = 2026) -> String {
        "{\"type\":\"turn_context\",\"timestamp\":\"\(year)-11-01T12:00:00.000Z\",\"payload\":{\"approval_policy\":\"never\",\"sandbox_policy\":{\"type\":\"workspace-write\",\"network_access\":true}}}"
    }

    /// Creates an independent filesystem fixture whose cleanup belongs to the calling test.
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Distinguishes a bounded miss from the same record becoming available within a larger window.
    @Test("A scan stops before evidence outside its byte budget")
    func respectsByteBudget() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout.jsonl")
        let content = record() + "\n" + String(repeating: record(year: 2036) + "\n", count: 600)
        try content.write(to: file, atomically: true, encoding: .utf8)
        let bounded = await CodexResumePermissionEvidenceReader(maximumBytes: 65_536)
            .permissionArguments(transcriptPath: file.path, before: cutoff)
        #expect(bounded.isEmpty)
        let complete = await CodexResumePermissionEvidenceReader()
            .permissionArguments(transcriptPath: file.path, before: cutoff)
        #expect(complete == expected)
    }

    /// Pins the production default limit independently of tests that inject a smaller budget.
    @Test("The default window ignores evidence beyond 4 MiB")
    func defaultWindowStopsBeforeOldEvidence() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout.jsonl")
        let content = record() + "\n" + String(repeating: record(year: 2036) + "\n", count: 26_000)
        #expect(content.utf8.count > 4 * 1024 * 1024)
        try content.write(to: file, atomically: true, encoding: .utf8)
        let result = await CodexResumePermissionEvidenceReader()
            .permissionArguments(transcriptPath: file.path, before: cutoff)
        #expect(result.isEmpty)
    }

    /// Verifies the delimiter probe recovers exact-edge records with either final-newline form.
    @Test("A complete record at the exact window edge is recovered", arguments: [true, false])
    func completeRecordAtWindowEdge(trailingNewline: Bool) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout.jsonl")
        let tail = record() + (trailingNewline ? "\n" : "")
        try ("ignored\n" + tail).write(to: file, atomically: true, encoding: .utf8)
        let result = await CodexResumePermissionEvidenceReader(maximumBytes: tail.utf8.count)
            .permissionArguments(transcriptPath: file.path, before: cutoff)
        #expect(result == expected)
    }

    /// Exercises backward chunk assembly across a large unrelated line and a newer ineligible turn.
    @Test("Chunk boundaries and final newlines preserve the latest eligible record", arguments: [true, false])
    func recordBoundaries(trailingNewline: Bool) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout.jsonl")
        let content = "invalid\n" + record() + "\n" + String(repeating: "x", count: 70_000)
            + "\n" + record(year: 2036) + (trailingNewline ? "\n" : "")
        try content.write(to: file, atomically: true, encoding: .utf8)
        let result = await CodexResumePermissionEvidenceReader()
            .permissionArguments(transcriptPath: file.path, before: cutoff)
        #expect(result == expected)
    }

    /// Prevents a JSON-looking suffix of an invalid physical line from becoming permission evidence.
    @Test("The first truncated line is never accepted as a complete record")
    func rejectsLeadingFragment() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout.jsonl")
        // The JSON-looking suffix is inside an invalid physical line.
        let suffix = record()
        try ("not-a-record:" + suffix).write(to: file, atomically: true, encoding: .utf8)
        let result = await CodexResumePermissionEvidenceReader(maximumBytes: suffix.utf8.count)
            .permissionArguments(transcriptPath: file.path, before: cutoff)
        #expect(result.isEmpty)
    }

    /// Keeps missing files, directories, empty files and nonblocking pipes from supplying evidence.
    @Test("Missing, empty and non-regular transcript paths return no evidence")
    func unavailableTranscript() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = root.appendingPathComponent("empty.jsonl")
        try Data().write(to: empty)
        let fifo = root.appendingPathComponent("pipe")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        for path in [root.path, empty.path, root.appendingPathComponent("missing").path, fifo.path] {
            let result = await CodexResumePermissionEvidenceReader()
                .permissionArguments(transcriptPath: path, before: cutoff)
            #expect(result.isEmpty)
        }
    }
}
