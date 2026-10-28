import Foundation
import Testing
@testable import CmuxNextCompat

struct DraftStateMigrationTests {
    @Test func changedBuildAdoptsNewestAttachmentsAndDoesNotClobberNewDraft() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "draft-migration-\(UUID().uuidString)")
        let older = root.appending(path: "builds/old")
        let newer = root.appending(path: "builds/new")
        let destination = root.appending(path: "drafts-v1/channel-nightly-next")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: older, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newer, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newer.appending(path: "agent-draft-attachments/chat"), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: older.appending(path: "agent-unsent-drafts.json"))
        try Data(#"{"tab":"newest"}"#.utf8).write(to: newer.appending(path: "agent-unsent-drafts.json"))
        try FileManager.default.createDirectory(at: newer.appending(path: "sessions/chat"), withIntermediateDirectories: true)
        try Data(#"{"id":"chat","composerDraft":"text from daemon"}"#.utf8).write(to: newer.appending(path: "sessions/chat/session.json"))
        try Data(#"{"session":"text from A"}"#.utf8).write(to: newer.appending(path: "agent-composer-drafts.json"))
        try Data("attachment".utf8).write(to: newer.appending(path: "agent-draft-attachments/chat/file"))
        let restored = root.appending(path: "drafts-v1/restored")
        DraftStateMigration.adopt(from: [older, newer], to: restored)
        #expect(String(data: try Data(contentsOf: restored.appending(path: "agent-unsent-drafts.json")), encoding: .utf8) == #"{"tab":"newest"}"#)
        #expect(String(data: try Data(contentsOf: restored.appending(path: "agent-composer-drafts.json")), encoding: .utf8) == #"{"session":"text from A"}"#)
        DraftStateMigration.adoptComposerDrafts(from: [newer], to: restored)
        #expect(String(data: try Data(contentsOf: restored.appending(path: "agent-composer-drafts.json")), encoding: .utf8)?.contains("text from daemon") == true)

        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data(#"{"tab":"typed-after-update"}"#.utf8).write(to: destination.appending(path: "agent-unsent-drafts.json"))

        DraftStateMigration.adopt(from: [older, newer], to: destination)

        // A non-empty B draft wins, while its missing attachment store is adopted.
        // The copied file stays byte-for-byte valid under the same relative attachment id.
        // (The source remains for rollback and a failed copy does not block launch.)
        #expect(String(data: try Data(contentsOf: destination.appending(path: "agent-unsent-drafts.json")), encoding: .utf8) == #"{"tab":"typed-after-update"}"#)
        #expect(String(data: try Data(contentsOf: destination.appending(path: "agent-draft-attachments/chat/file")), encoding: .utf8) == "attachment")
        #expect(FileManager.default.fileExists(atPath: newer.appending(path: "agent-draft-attachments/chat/file").path))
        #expect(String(data: try Data(contentsOf: destination.appending(path: "agent-unsent-drafts.json")), encoding: .utf8) == #"{"tab":"typed-after-update"}"#)
    }
}
