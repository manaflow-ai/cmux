import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite struct ClaudeTranscriptAccountSyncTests {
    private let fm = FileManager.default

    private func makeRoot() throws -> String {
        let root = NSTemporaryDirectory() + "acct-sync-\(UUID().uuidString)"
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        return root
    }

    private func slug(_ cwd: String) -> String { ClaudeProjectSlug().slug(forWorkingDirectory: cwd) }

    @discardableResult
    private func seedSource(
        root: String, cwd: String, body: String = "line1\nline2\nline3\n", mtime: Date? = nil
    ) throws -> String {
        let project = "\(root)/src/projects/\(slug(cwd))"
        try fm.createDirectory(atPath: "\(project)/s1/subagents", withIntermediateDirectories: true)
        try body.write(toFile: "\(project)/s1.jsonl", atomically: true, encoding: .utf8)
        try "sub".write(toFile: "\(project)/s1/subagents/a.jsonl", atomically: true, encoding: .utf8)
        if let mtime { try fm.setAttributes([.modificationDate: mtime], ofItemAtPath: "\(project)/s1.jsonl") }
        return "\(project)/s1.jsonl"
    }

    private func request(root: String, cwd: String, sid: String = "s1") -> ClaudeTranscriptAccountSyncRequest {
        .init(sessionID: sid, workingDirectory: cwd, sourceConfigDirectory: "\(root)/src",
              targetConfigDirectory: "\(root)/dst")
    }

    @Test func copiesWhenTargetMissing() async throws {
        let root = try makeRoot(); defer { try? fm.removeItem(atPath: root) }
        let src = try seedSource(root: root, cwd: "/p")
        let outcome = try await ClaudeTranscriptAccountSync().sync(request(root: root, cwd: "/p"))
        #expect(outcome == .copied)
        let dst = "\(root)/dst/projects/\(slug("/p"))/s1.jsonl"
        #expect(try Data(contentsOf: URL(fileURLWithPath: dst)) == Data(contentsOf: URL(fileURLWithPath: src)))
        #expect(fm.fileExists(atPath: "\(root)/dst/projects/\(slug("/p"))/s1/subagents/a.jsonl"))
        // A second sync must see the copy as current.
        let again = try await ClaudeTranscriptAccountSync().sync(request(root: root, cwd: "/p"))
        #expect(again == .alreadyCurrent)
    }

    @Test func refreshesStaleTarget() async throws {
        let root = try makeRoot(); defer { try? fm.removeItem(atPath: root) }
        let now = Date()
        let src = try seedSource(root: root, cwd: "/p", mtime: now.addingTimeInterval(60))
        let dstProject = "\(root)/dst/projects/\(slug("/p"))"
        try fm.createDirectory(atPath: "\(dstProject)/s1/old", withIntermediateDirectories: true)
        try "line1\n".write(toFile: "\(dstProject)/s1.jsonl", atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: now], ofItemAtPath: "\(dstProject)/s1.jsonl")
        let outcome = try await ClaudeTranscriptAccountSync().sync(request(root: root, cwd: "/p"))
        #expect(outcome == .refreshed)
        #expect(try Data(contentsOf: URL(fileURLWithPath: "\(dstProject)/s1.jsonl"))
                == Data(contentsOf: URL(fileURLWithPath: src)))
        #expect(fm.fileExists(atPath: "\(dstProject)/s1/subagents/a.jsonl"))
        #expect(!fm.fileExists(atPath: "\(dstProject)/s1/old"))
        let leftovers = try fm.contentsOfDirectory(atPath: dstProject).filter { $0.contains(".tmp-") }
        #expect(leftovers.isEmpty)
    }

    @Test func keepsNewerTarget() async throws {
        let root = try makeRoot(); defer { try? fm.removeItem(atPath: root) }
        let now = Date()
        try seedSource(root: root, cwd: "/p", mtime: now)
        let dstProject = "\(root)/dst/projects/\(slug("/p"))"
        try fm.createDirectory(atPath: "\(dstProject)/s1", withIntermediateDirectories: true)
        try "newer target\n".write(toFile: "\(dstProject)/s1.jsonl", atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(60)], ofItemAtPath: "\(dstProject)/s1.jsonl")
        let outcome = try await ClaudeTranscriptAccountSync().sync(request(root: root, cwd: "/p"))
        #expect(outcome == .alreadyCurrent)
        #expect(try String(contentsOfFile: "\(dstProject)/s1.jsonl", encoding: .utf8) == "newer target\n")
    }

    @Test func syncsTranscriptForCwdWithSpacesAndUnicode() async throws {
        let root = try makeRoot(); defer { try? fm.removeItem(atPath: root) }
        let cwd = "/tmp/my proj/한글"
        try seedSource(root: root, cwd: cwd)
        let outcome = try await ClaudeTranscriptAccountSync().sync(request(root: root, cwd: cwd))
        #expect(outcome == .copied)
        #expect(fm.fileExists(atPath: "\(root)/dst/projects/\(slug(cwd))/s1.jsonl"))
    }

    @Test func missingSourceThrows() async throws {
        let root = try makeRoot(); defer { try? fm.removeItem(atPath: root) }
        await #expect(throws: ClaudeTranscriptAccountSyncError.transcriptNotFound) {
            try await ClaudeTranscriptAccountSync().sync(request(root: root, cwd: "/p"))
        }
    }

    @Test func rejectsUnsafeSessionID() async throws {
        let root = try makeRoot(); defer { try? fm.removeItem(atPath: root) }
        await #expect(throws: ClaudeTranscriptAccountSyncError.invalidSessionID) {
            try await ClaudeTranscriptAccountSync().sync(request(root: root, cwd: "/p", sid: "../x"))
        }
    }

    @Test func findsSourceInOtherProjectDirWhenCwdSlugDiffers() async throws {
        let root = try makeRoot(); defer { try? fm.removeItem(atPath: root) }
        try seedSource(root: root, cwd: "/old/cwd")
        let outcome = try await ClaudeTranscriptAccountSync().sync(request(root: root, cwd: "/new/cwd"))
        #expect(outcome == .copied)
        #expect(fm.fileExists(atPath: "\(root)/dst/projects/\(slug("/new/cwd"))/s1.jsonl"))
    }
}
