import Darwin
import Foundation
import Testing
@testable import CmuxNextCompat

nonisolated struct DraftStateMigrationTests {
    @Test func changedBuildAdoptsNewestAttachmentsAndDoesNotClobberNewDraft() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("old/agent-unsent-drafts.json", #"{"tab":"older"}"#, date: 10)
        try fixture.write("new/agent-unsent-drafts.json", #"{"tab":"newest"}"#, date: 20)
        try fixture.write("new/agent-composer-drafts.json", #"{"session":"text from A"}"#)
        try fixture.write("new/sessions/chat/session.json", #"{"id":"chat","composerDraft":"text from daemon"}"#)
        try fixture.write("new/agent-draft-attachments/chat/file", "attachment")
        try fixture.write("new/agent-queued-edits.json", #"{"chat":{"prompt":{"text":"pending queue edit"}}}"#)
        try fixture.write("destination/agent-unsent-drafts.json", #"{"tab":"typed-after-update"}"#)

        DraftStateMigration.adopt(from: [fixture.url("old"), fixture.url("new")], to: fixture.url("destination"))
        DraftStateMigration.adoptComposerDrafts(from: [fixture.url("new")], to: fixture.url("destination"))

        let unsent = try fixture.object("destination/agent-unsent-drafts.json")
        let composer = try fixture.object("destination/agent-composer-drafts.json")
        #expect(unsent["tab"] as? String == "typed-after-update")
        #expect(composer["session"] as? String == "text from A")
        #expect(composer["chat"] as? String == "text from daemon")
        #expect(try fixture.text("destination/agent-draft-attachments/chat/file") == "attachment")
        #expect(try fixture.text("new/agent-draft-attachments/chat/file") == "attachment")
        #expect(try fixture.text("destination/agent-queued-edits.json") == fixture.text("new/agent-queued-edits.json"))
    }

    @Test func unsentDraftsMergeMissingTabsAndPreserveExistingEmptyDrafts() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("old/agent-unsent-drafts.json", #"{"missing":"stale","olderOnly":"not from newest root"}"#, date: 10)
        try fixture.write("new/agent-unsent-drafts.json", #"{"missing":"recover A","overlap":"A old value","cleared":"A old cleared value"}"#, date: 20)
        try fixture.write("destination/agent-unsent-drafts.json", #"{"overlap":"B current","distinct":"B only","cleared":""}"#)

        DraftStateMigration.adopt(from: [fixture.url("new"), fixture.url("old")], to: fixture.url("destination"))

        let drafts = try fixture.object("destination/agent-unsent-drafts.json")
        #expect(drafts["missing"] as? String == "recover A")
        #expect(drafts["overlap"] as? String == "B current")
        #expect(drafts["distinct"] as? String == "B only")
        #expect(drafts["cleared"] as? String == "")
        #expect(drafts["olderOnly"] == nil)
        #expect(drafts.count == 4)
    }

    @Test func attachmentRecordsAndLegacyStringsMergeIntoReadableRecords() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("source/agent-unsent-drafts.json", #"{"missing":"legacy A","overlap":"old A","cleared":"old A"}"#)
        try fixture.write("destination/agent-unsent-drafts.json", #"{"overlap":{"text":"B current","attachments":[{"id":"image","kind":"image","data":"payload"}]},"cleared":{"text":"","attachments":[]}}"#)

        DraftStateMigration.adopt(from: [fixture.url("source")], to: fixture.url("destination"))

        let drafts = try fixture.object("destination/agent-unsent-drafts.json")
        let missing = try #require(drafts["missing"] as? [String: Any])
        let overlap = try #require(drafts["overlap"] as? [String: Any])
        let cleared = try #require(drafts["cleared"] as? [String: Any])
        #expect(missing["text"] as? String == "legacy A")
        #expect((missing["attachments"] as? [Any])?.isEmpty == true)
        #expect(overlap["text"] as? String == "B current")
        #expect((overlap["attachments"] as? [[String: Any]])?.first?["data"] as? String == "payload")
        #expect(cleared["text"] as? String == "")
    }

    @Test func newAttachmentRecordPromotesExistingLegacyDraftWithoutChangingItsText() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("source/agent-unsent-drafts.json", #"{"missing":{"text":"A","attachments":[{"id":"image","data":"payload"}]}}"#)
        try fixture.write("destination/agent-unsent-drafts.json", #"{"existing":"B","cleared":""}"#)

        DraftStateMigration.adopt(from: [fixture.url("source")], to: fixture.url("destination"))

        let drafts = try fixture.object("destination/agent-unsent-drafts.json")
        #expect((drafts["existing"] as? [String: Any])?["text"] as? String == "B")
        #expect((drafts["cleared"] as? [String: Any])?["text"] as? String == "")
        let missing = try #require(drafts["missing"] as? [String: Any])
        #expect((missing["attachments"] as? [[String: Any]])?.first?["data"] as? String == "payload")
    }

    @Test func composerDraftsMergePerSessionWithoutReplacingDestinationClears() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("source/agent-composer-drafts.json", #"{"missing":"A","overlap":"A old","cleared":"A old"}"#)
        try fixture.write("destination/agent-composer-drafts.json", #"{"overlap":"B","distinct":"B only","cleared":""}"#)

        DraftStateMigration.adopt(from: [fixture.url("source")], to: fixture.url("destination"))

        let drafts = try fixture.object("destination/agent-composer-drafts.json")
        #expect(drafts["missing"] as? String == "A")
        #expect(drafts["overlap"] as? String == "B")
        #expect(drafts["distinct"] as? String == "B only")
        #expect(drafts["cleared"] as? String == "")
    }

    @Test func daemonRecoveryUsesNewestMetadataPerSessionAndPreservesDestination() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("old/sessions/chat/session.json", #"{"id":"chat","composerDraft":"old"}"#, date: 10)
        try fixture.write("new/sessions/chat/session.json", #"{"id":"chat","composerDraft":"new"}"#, date: 20)
        try fixture.write("old/sessions/cleared/session.json", #"{"id":"cleared","composerDraft":"do not resurrect"}"#, date: 10)
        try fixture.write("new/sessions/cleared/session.json", #"{"id":"cleared"}"#, date: 20)
        try fixture.write("new/sessions/current/session.json", #"{"id":"current","composerDraft":"old daemon text"}"#)
        try fixture.write("destination/agent-composer-drafts.json", #"{"current":"","distinct":"B only"}"#)

        DraftStateMigration.adoptComposerDrafts(from: [fixture.url("new"), fixture.url("absent"), fixture.url("old")], to: fixture.url("destination"))

        let drafts = try fixture.object("destination/agent-composer-drafts.json")
        #expect(drafts["chat"] as? String == "new")
        #expect(drafts["cleared"] == nil)
        #expect(drafts["current"] as? String == "")
        #expect(drafts["distinct"] as? String == "B only")
    }

    @Test func quickDraftFileIsAdoptedOnlyWhenDestinationIsAbsent() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("source/quick-composer-draft.json", #""quick A""#)
        try fixture.write("existing/quick-composer-draft.json", #""""#)
        try fixture.write("current/quick-composer-draft.json", #""older Quick""#)
        try fixture.write("current/agent-composer-drafts.json", #"{"quick-composer-v1":""}"#)

        DraftStateMigration.adopt(from: [fixture.url("source")], to: fixture.url("missing"))
        DraftStateMigration.adopt(from: [fixture.url("source")], to: fixture.url("existing"))

        #expect(try fixture.text("missing/quick-composer-draft.json") == #""quick A""#)
        #expect(try fixture.text("existing/quick-composer-draft.json") == #""""#)
        for target in ["missing", "existing", "current"] {
            DraftStateMigration.adoptComposerDrafts(from: [], to: fixture.url(target))
        }
        #expect((try fixture.object("missing/agent-composer-drafts.json"))["quick-composer-v1"] as? String == "quick A")
        #expect((try fixture.object("existing/agent-composer-drafts.json"))["quick-composer-v1"] as? String == "")
        #expect((try fixture.object("current/agent-composer-drafts.json"))["quick-composer-v1"] as? String == "")
    }

    @Test func settledArtifactsStayClearedAfterASeparateArtifactFails() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("source/agent-draft-attachments/chat/file", "restored attachment")
        try fixture.write("source/agent-pane-wake-states.json", #"{"chat":{"scrollTop":12}}"#)
        try fixture.write("source/agent-unsent-drafts.json", "malformed source")

        DraftStateMigration.adopt(from: [fixture.url("source")], to: fixture.url("destination"))
        #expect(try fixture.text("destination/agent-draft-attachments/chat/file") == "restored attachment")
        #expect(try fixture.text("destination/agent-pane-wake-states.json") == #"{"chat":{"scrollTop":12}}"#)

        try FileManager.default.removeItem(at: fixture.url("destination/agent-draft-attachments"))
        try FileManager.default.removeItem(at: fixture.url("destination/agent-pane-wake-states.json"))
        DraftStateMigration.adopt(from: [fixture.url("source")], to: fixture.url("destination"))
        #expect(!FileManager.default.fileExists(atPath: fixture.url("destination/agent-draft-attachments").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.url("destination/agent-pane-wake-states.json").path))
    }

    @Test(arguments: ["chat-a/2", "chat-b/1"])
    func failedArtifactCopyPublishesNoPartialDataAndRetriesEveryLeaf(failing: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for path in ["chat-a/1", "chat-a/2", "chat-b/1"] {
            try fixture.write("source/agent-draft-attachments/\(path)", path)
        }
        try fixture.write("destination/agent-draft-attachments/current/1", "B current")
        try fixture.write("source/agent-draft-attachments/current/legacy", "older A")
        DraftStateMigration.adopt(from: [fixture.url("source")], to: fixture.url("destination")) { source, target in
            if source.path.hasSuffix(failing) { throw CopyFailure.injected }
            try FileManager.default.copyItem(at: source, to: target)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.url("destination/agent-draft-attachments/chat-a").path))
        #expect(try fixture.text("destination/agent-draft-attachments/current/1") == "B current")
        try FileManager.default.removeItem(at: fixture.url("destination/agent-draft-attachments/current"))
        DraftStateMigration.adopt(from: [fixture.url("source")], to: fixture.url("destination"))
        for path in ["chat-a/1", "chat-a/2", "chat-b/1"] {
            #expect(try fixture.text("destination/agent-draft-attachments/\(path)") == path)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.url("destination/agent-draft-attachments/current/legacy").path))
    }

    @Test(arguments: ["missing", "empty", "current"])
    func publicationFailureLeavesCanonicalRootUntouchedAndRetryPublishes(state: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("source/agent-unsent-drafts.json", #"{"new":"A"}"#)
        if state != "missing" { try FileManager.default.createDirectory(at: fixture.url("destination"), withIntermediateDirectories: true) }
        if state == "current" { try fixture.write("destination/agent-unsent-drafts.json", #"{"old":"B"}"#) }
        if state != "missing" {
            try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: fixture.url("destination").path)
        }
        let before = try? FileManager.default.contentsOfDirectory(atPath: fixture.url("destination").path)
        DraftStateMigration.adopt(from: [fixture.url("source")], to: fixture.url("destination"), renameItem: { source, target, flags in
            #expect(flags == UInt32(state == "missing" ? RENAME_EXCL : RENAME_SWAP))
            #expect(FileManager.default.fileExists(atPath: source.appending(path: "agent-unsent-drafts.json").path))
            #expect(target == fixture.url("destination"))
            return -1
        }) {
            try FileManager.default.copyItem(at: $0, to: $1)
        }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: fixture.url("destination").path)) == before)
        if state == "current" { #expect(try fixture.text("destination/agent-unsent-drafts.json") == #"{"old":"B"}"#) }
        DraftStateMigration.adopt(from: [fixture.url("source")], to: fixture.url("destination"))
        let drafts = try fixture.object("destination/agent-unsent-drafts.json")
        #expect(drafts["new"] as? String == "A")
        if state == "current" { #expect(drafts["old"] as? String == "B") }
        let permissions = try FileManager.default.attributesOfItem(atPath: fixture.url("destination").path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == (state == "missing" ? 0o700 : 0o750))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).allSatisfy { !$0.hasPrefix(".draft-adoption-") })
    }

    private enum CopyFailure: Error { case injected }

    @Test func malformedDestinationIsKeptAndAdoptionCanRetry() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("source/agent-unsent-drafts.json", #"{"tab":"A"}"#)
        try fixture.write("destination/agent-unsent-drafts.json", "unreadable B")

        DraftStateMigration.adopt(from: [fixture.url("source")], to: fixture.url("destination"))

        #expect(try fixture.text("destination/agent-unsent-drafts.json") == "unreadable B")
        #expect(!FileManager.default.fileExists(atPath: fixture.url("destination/.adopted-v1").path))
        try FileManager.default.removeItem(at: fixture.url("destination/agent-unsent-drafts.json"))
        DraftStateMigration.adopt(from: [fixture.url("source")], to: fixture.url("destination"))
        #expect((try fixture.object("destination/agent-unsent-drafts.json"))["tab"] as? String == "A")
    }

    private nonisolated struct Fixture {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "draft-migration-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func url(_ path: String) -> URL { root.appending(path: path) }
        func remove() { try? FileManager.default.removeItem(at: root) }

        func write(_ path: String, _ text: String, date: TimeInterval? = nil) throws {
            let file = url(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
            if let date { try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: date)], ofItemAtPath: file.path) }
        }

        func text(_ path: String) throws -> String { try String(contentsOf: url(path), encoding: .utf8) }
        func object(_ path: String) throws -> [String: Any] {
            try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url(path))) as? [String: Any])
        }
    }
}
