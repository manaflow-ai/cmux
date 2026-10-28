import Darwin
import Foundation
import Testing
import CmuxNextWakeups
@testable import CmuxNextAgentPane
@testable import CmuxNextCompat

nonisolated struct DraftStateMigrationTests {
    @Test func changedBuildAdoptsNewestAttachmentsAndDoesNotClobberNewDraft() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("old/agent-unsent-drafts.json", #"{"tab":"older"}"#, date: 10)
        try fixture.write("new/agent-unsent-drafts.json", #"{"tab":"newest"}"#, date: 20)
        try fixture.write("new/agent-composer-drafts.json", #"{"session":"text from A"}"#)
        try fixture.write("new/agent-draft-attachments/chat/file", "attachment")
        try fixture.write("new/agent-queued-edits.json", #"{"chat":{"prompt":{"text":"pending queue edit"}}}"#)
        try fixture.write("destination/agent-unsent-drafts.json", #"{"tab":"typed-after-update"}"#)

        DraftStateMigration.adopt(from: [fixture.url("old"), fixture.url("new")], to: fixture.url("destination"))

        let unsent = try fixture.object("destination/agent-unsent-drafts.json")
        let composer = try fixture.object("destination/agent-composer-drafts.json")
        #expect(unsent["tab"] as? String == "typed-after-update")
        #expect(composer["session"] as? String == "text from A")
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

    @Test func quickDraftFileIsAdoptedOnlyWhenDestinationIsAbsent() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("source/quick-composer-draft.json", #""quick A""#)
        try fixture.write("existing/quick-composer-draft.json", #""""#)

        DraftStateMigration.adopt(from: [fixture.url("source")], to: fixture.url("missing"))
        DraftStateMigration.adopt(from: [fixture.url("source")], to: fixture.url("existing"))

        #expect(try fixture.text("missing/quick-composer-draft.json") == #""quick A""#)
        #expect(try fixture.text("existing/quick-composer-draft.json") == #""""#)

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

    @Test(arguments: [false, true])
    func failedPublicationThenWriterClearNeverRestoresAnExistingOrNewChat(createdAfterFailure: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = await AgentPaneDraftAttachments(directory: fixture.url("destination"))
        let folder = try #require(await store.folder(for: "current"))
        let chip = AgentPaneWakeState.Attachment(id: "B", kind: "link", name: "current", mimeType: "inode/directory", size: 0, path: "/tmp/current")
        let list = AgentPaneDraftAttachments.json([chip])
        try fixture.write("source/agent-draft-attachments/\(folder.lastPathComponent)/legacy", "older A")
        if !createdAfterFailure {
            let saved = try JSONEncoder().encode(AgentPaneDraftAttachments.Saved(attachments: [chip], files: nil))
            try fixture.write("destination/agent-draft-attachments/\(folder.lastPathComponent)/draft.json", String(decoding: saved, as: UTF8.self))
        }
        failPublication(fixture)
        if createdAfterFailure { _ = await store.keep(list, for: "current") }
        #expect(FileManager.default.fileExists(atPath: folder.path))
        _ = await store.keep(.array([]), for: "current")
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        DraftStateMigration.adopt(from: [fixture.url("source")], to: fixture.url("destination"))
        #expect(!FileManager.default.fileExists(atPath: folder.path), "a writer-cleared chat was imported again")
    }

    @Test func anOwnershipWriteFailureDoesNotAcknowledgeOrDeleteCurrentAttachments() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = await AgentPaneDraftAttachments(directory: fixture.url("destination"))
        let folder = try #require(await store.folder(for: "current"))
        let chip = AgentPaneWakeState.Attachment(id: "B", kind: "link", name: "current", mimeType: "inode/directory", size: 0, path: "/tmp/current")
        _ = await store.keep(AgentPaneDraftAttachments.json([chip]), for: "current")
        let markers = fixture.url("destination/.owned-v1-agent-draft-attachments")
        try? FileManager.default.removeItem(at: markers)
        try fixture.write("destination/.owned-v1-agent-draft-attachments", "blocked metadata directory")
        let reply = await store.keep(.array([]), for: "current")
        #expect(reply == nil)
        #expect(FileManager.default.fileExists(atPath: folder.path))
        #expect(await store.attachments(for: "current").map(\.id) == ["B"])
    }

    @Test func failedPublicationThenUnsentClearAndMoveKeepTheirOwnership() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("source/agent-unsent-drafts.json", #"{"cleared":"A","provisional":"A","real":"A"}"#)
        failPublication(fixture)
        let writer = await MainActor.run {
            let drafts = AgentUnsentDrafts(directory: fixture.url("destination"))
            drafts.set("B", for: "cleared")
            drafts.set("", for: "cleared")
            drafts.set("B moved", for: "provisional")
            drafts.move("provisional", to: "real")
            drafts.move("provisional", to: "real")
            #expect(!drafts.hasDraft("cleared") && !drafts.hasDraft("provisional"))
            #expect(drafts.seed(for: "cleared", session: nil) == nil)
            return drafts
        }
        await writer.flush()
        DraftStateMigration.adopt(from: [fixture.url("source")], to: fixture.url("destination"))
        let drafts = try fixture.object("destination/agent-unsent-drafts.json")
        #expect(drafts["cleared"] as? String == "")
        #expect(drafts["provisional"] as? String == "")
        #expect(drafts["real"] as? String == "B moved")
    }

    @Test(arguments: ["consume", "emptySave", "emptyConsume"])
    func failedPublicationThenWakeConsumptionOrSaveKeepsItsOwnership(operation: String) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("source/agent-pane-wake-states.json", #"{"chat":{"shell":true,"shellText":"A"}}"#)
        try fixture.write("source/agent-pane-wake-attachments/legacy", "older A")
        if operation == "consume" {
            try fixture.write("destination/agent-pane-wake-states.json", #"{"chat":{"shell":true,"shellText":"B"}}"#)
            try fixture.write("destination/agent-pane-wake-attachments/current", "current B")
        }
        failPublication(fixture)
        let wake = await AgentPaneRelaunchWake(directory: fixture.url("destination"))
        if operation == "emptySave" {
            await wake.save([:])
        } else {
            let states = await wake.take(on: BackgroundWork())
            if operation == "consume" { #expect(states["chat"]?.shellText == "B") }
        }
        DraftStateMigration.adopt(from: [fixture.url("source")], to: fixture.url("destination"))
        let shouldRestore = operation == "emptyConsume"
        #expect(FileManager.default.fileExists(atPath: fixture.url("destination/agent-pane-wake-states.json").path) == shouldRestore)
        #expect(FileManager.default.fileExists(atPath: fixture.url("destination/agent-pane-wake-attachments/legacy").path) == shouldRestore)
    }

    private func failPublication(_ fixture: Fixture) {
        DraftStateMigration.adopt(from: [fixture.url("source")], to: fixture.url("destination"), renameItem: { _, _, _ in -1 }) {
            try FileManager.default.copyItem(at: $0, to: $1)
        }
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
