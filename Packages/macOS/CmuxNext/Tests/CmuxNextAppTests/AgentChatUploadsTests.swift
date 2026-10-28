import CmuxNextAgentLanes
import CmuxNextAgentPane
import CmuxNextBridge
@testable import CmuxNextApp
import Foundation
import Testing

/// Any file attaches in a chat on this Mac (Lawrence 2026-10-20): what the composer can't put in
/// the prompt (a binary, a large text file) is saved owner-only and named by its path.
@Suite struct AgentChatUploadsTests {
    @Test func savesEachFileOwnerOnlyUnderItsOwnName() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "agent-chat-uploads-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "upload", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let binary = Data([0, 1, 2, 0xff])
        let files = [AgentPaneUpload(name: "state.sqlite", data: binary), AgentPaneUpload(name: "state.sqlite", data: Data("b".utf8)),
                     AgentPaneUpload(name: "index.html", data: Data("<p>x</p>".utf8))]
        let paths = try AgentChatUploads.write(files, in: folder)
        #expect(paths.count == 3)
        #expect(Set(paths).count == 3, "two files with one name keep both")
        #expect(paths.map { ($0 as NSString).lastPathComponent } == ["state.sqlite", "state.sqlite", "index.html"])
        #expect(try Data(contentsOf: URL(fileURLWithPath: paths[0])) == binary)
        let mode = try FileManager.default.attributesOfItem(atPath: paths[2])[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let folderMode = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int
        #expect(folderMode == 0o700)
    }

    /// Nothing ever deleted a chat's uploads. A deleted chat's go with it, and any older than the
    /// age cap goes at launch; what the app did not name, a symlink and a file stay.
    @Test func aDeletedChatsUploadsAndOldOnesGoAndNothingElse() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appending(path: "agent-chat-uploads-\(UUID().uuidString)", directoryHint: .isDirectory)
        let outside = root.appendingPathExtension("outside")
        defer {
            try? manager.removeItem(at: root)
            try? manager.removeItem(at: outside)
        }
        let now = Date()
        func upload(_ chat: String?, age days: Double) throws -> URL {
            let parent = chat.map { AgentChatUploads.chatFolder($0, in: root) } ?? root
            let folder = parent.appending(path: UUID().uuidString.lowercased(), directoryHint: .isDirectory)
            _ = try AgentChatUploads.write([AgentPaneUpload(name: "a.txt", data: Data("x".utf8))], in: folder)
            try manager.setAttributes([.creationDate: now.addingTimeInterval(-days * 86_400)], ofItemAtPath: folder.path)
            return folder
        }
        let old = try upload("chat-a", age: 31), new = try upload("chat-a", age: 1)
        let onlyOld = try upload("chat-b", age: 40), newChatOld = try upload(nil, age: 45), newChatNew = try upload(nil, age: 2)
        let notes = AgentChatUploads.chatFolder("chat-c", in: root).appending(path: "notes", directoryHint: .isDirectory)
        try manager.createDirectory(at: notes, withIntermediateDirectories: true)
        try manager.setAttributes([.creationDate: now.addingTimeInterval(-90 * 86_400)], ofItemAtPath: notes.path)
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: outside.appending(path: "keep.txt"))
        try manager.createSymbolicLink(at: AgentChatUploads.chatFolder("chat-d", in: root), withDestinationURL: outside)
        try manager.createSymbolicLink(at: root.appending(path: UUID().uuidString.lowercased()), withDestinationURL: outside)

        #expect(AgentChatUploads.sweep(root, now: now) == 3)
        #expect(!manager.fileExists(atPath: old.path) && manager.fileExists(atPath: new.path))
        #expect(!manager.fileExists(atPath: onlyOld.deletingLastPathComponent().path), "an emptied chat folder goes")
        #expect(!manager.fileExists(atPath: newChatOld.path) && manager.fileExists(atPath: newChatNew.path))
        #expect(manager.fileExists(atPath: notes.path))
        #expect(manager.fileExists(atPath: outside.appending(path: "keep.txt").path))
        #expect(AgentChatUploads.sweep(root, now: now) == 0)

        // A deleted chat's folder goes; another chat's, a link and a name that is no session id stay.
        let uuidChat = try upload("0190a000-0000-7000-8000-000000000001", age: 1)
        AgentChatUploads.remove(session: "chat-a", in: root)
        AgentChatUploads.remove(session: "0190a000-0000-7000-8000-000000000001", in: root)
        #expect(!manager.fileExists(atPath: new.deletingLastPathComponent().path))
        #expect(!manager.fileExists(atPath: uuidChat.deletingLastPathComponent().path))
        #expect(manager.fileExists(atPath: newChatNew.path))
        AgentChatUploads.remove(session: "chat-d", in: root)
        AgentChatUploads.remove(session: "../outside", in: root)
        #expect(manager.fileExists(atPath: outside.appending(path: "keep.txt").path))
        #expect(manager.fileExists(atPath: notes.path))
    }

    @Test func aSessionIdIsOneFolderName() {
        for good in ["0190a000-0000-7000-8000-000000000001", "chat_1"] { #expect(AgentChatUploads.isSessionName(good), "\(good)") }
        for bad in ["", ".", "..", "a/b", "huge-blue/chat", "é"] { #expect(!AgentChatUploads.isSessionName(bad), "\(bad)") }
    }
}

/// Only this Mac's acpmux deleting one of its own chats deletes the chat's uploads. The watch also
/// relays a peer's or the Cloud VM's purge (a Cloud lease ending relays one per chat, under the
/// chat's own id), and Bring Back purges the closed copy it replaces under the same id: those
/// chats still exist, and their prompts name the files.
@MainActor
@Suite(.serialized)
struct AgentChatUploadsPurgeTests {
    @Test func onlyThisMacsOwnDeleteDeletesAChatsUploads() async throws {
        let acpmux = try StandInAcpmux(sessions: [])
        let feed = AgentTurnStateFeed(socketPath: acpmux.path, turns: AgentTurnStateStore())
        var deleted: [String] = []
        let previous = AgentTurnStateFeed.purged
        AgentTurnStateFeed.purged = { deleted.append($0) }
        defer { AgentTurnStateFeed.purged = previous }
        feed.start(localHost: "install:chat-uploads")
        func purged(_ id: String, _ extra: [String: Any] = [:]) -> [String: Any] {
            let params: [String: Any] = ["sessionId": id, "session": ["sessionId": id], "kind": "purged", "recordKind": "purged", "seq": 1]
            return params.merging(extra) { $1 }
        }
        acpmux.push(params: purged("on-cloud", ["peer": "cloud-vm"]))
        acpmux.push(params: purged("brought-back", ["replaced": true]))
        acpmux.push(params: purged("deleted"))
        let deadline = ContinuousClock.now + .seconds(5)
        while deleted.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(deleted == ["deleted"])
        withExtendedLifetime((acpmux, feed)) {}
    }
}
