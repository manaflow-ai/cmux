import AppKit
@testable import CmuxNextAgentPane
import Foundation
import Testing

/// macOS removes its floating recording preview when a drag finishes. A local chat must keep the
/// recording before returning a link, rather than keep a URL into that preview's temporary folder.
@MainActor @Suite(.serialized)
struct AgentPaneRecordingDropTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private final class Uptime {
        var now: TimeInterval = 1000
    }

    private final class Rig {
        let model = AgentPaneModel(host: NoHost())
        let clock = Uptime()
        var dragged: [URL] = []
        let saved: URL

        init(saved: URL) {
            self.saved = saved
            let clock = clock
            model.droppedPaths = AgentPaneDroppedPaths(now: { clock.now })
            model.onLocalPaths = { true }
            model.chatUploadFolders = ChatUploadFolders(root: saved)
            model.replyLinks.mouseHeld = { true }
            model.replyLinks.startDrag = { [weak self] in self?.dragged.append($0); return true }
        }

        /// The files kept under the Chat Uploads root.
        var keptFiles: [URL] {
            let found = FileManager.default.enumerator(at: saved, includingPropertiesForKeys: [.isRegularFileKey])
            return (found?.allObjects as? [URL] ?? []).filter {
                (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
        }

        func ask(_ names: [String]) async -> [String: Any] {
            await model.respond(to: AgentPaneRequest(body: ["method": "chat.attach.dropped", "params": ["kind": "drop", "names": names]]))
        }
    }

    private static func folder(_ name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func preview(_ name: String = "Screen Recording.mov", data: Data) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TemporaryItems", isDirectory: true)
            .appendingPathComponent("NSIRD_screencaptureui_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name)
        try data.write(to: file)
        return file
    }

    private static func paths(_ reply: [String: Any]) -> [String] {
        let value = reply["value"] as? [String: Any]
        return (value?["items"] as? [[String: Any]])?.compactMap { $0["path"] as? String } ?? []
    }

    @Test func aRecordingSurvivesItsPreviewClosingAndCanBeDraggedOutAgain() async throws {
        let data = Data([0, 0, 0, 20, 0x66, 0x74, 0x79, 0x70, 0x71, 0x74, 0x20, 0x20])
        let source = try Self.preview(data: data)
        let saved = try Self.folder("recording-saved")
        defer {
            try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: saved)
        }
        let rig = Rig(saved: saved)
        rig.model.droppedPaths.stash([source], kind: .drop)
        // The OS owns this folder and may unlink it before the page asks for its local path.
        try FileManager.default.removeItem(at: source.deletingLastPathComponent())
        let paths = Self.paths(await rig.ask([source.lastPathComponent]))
        let kept = URL(fileURLWithPath: try #require(paths.first))
        #expect(kept.path != source.path)
        #expect(kept.lastPathComponent == source.lastPathComponent)
        #expect(try Data(contentsOf: kept) == data)
        // Kept in the chat's Chat Uploads folder, owner-only.
        #expect(kept.resolvingSymlinksInPath().path.hasPrefix(saved.resolvingSymlinksInPath().path + "/"))
        let mode = try FileManager.default.attributesOfItem(atPath: kept.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)

        let reply = await rig.model.respond(to: AgentPaneRequest(body: ["method": "file.drag", "params": ["path": kept.path]]))
        #expect(reply["ok"] as? Bool == true)
        #expect(rig.dragged.map { $0.resolvingSymlinksInPath() } == [kept.resolvingSymlinksInPath()])
        let exported = saved.appendingPathComponent("Desktop export.mov")
        try FileManager.default.copyItem(at: try #require(rig.dragged.first), to: exported)
        #expect(try Data(contentsOf: exported) == data)
        // Retaining one recording does not grant access to other files beside its copy.
        let other = kept.deletingLastPathComponent().appendingPathComponent("not-dropped.mov")
        try Data("private".utf8).write(to: other)
        let refused = await rig.model.respond(to: AgentPaneRequest(body: ["method": "file.drag", "params": ["path": other.path]]))
        #expect(refused["ok"] as? Bool == false)
        #expect(rig.dragged.count == 1)
    }

    @Test func expiredOrMismatchedRecordsNeverSaveARecording() async throws {
        let source = try Self.preview(data: Data("movie".utf8))
        let saved = try Self.folder("recording-expired")
        defer {
            try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: saved)
        }
        let rig = Rig(saved: saved)
        rig.model.droppedPaths.stash([source], kind: .drop)
        rig.clock.now += AgentPaneDroppedPaths.lifetime + 1
        #expect(Self.paths(await rig.ask([source.lastPathComponent])).isEmpty)
        rig.model.droppedPaths.stash([source], kind: .drop)
        #expect(Self.paths(await rig.ask(["another.mov"])).isEmpty)
        #expect(Self.paths(await rig.ask([source.lastPathComponent])).isEmpty)
        #expect(rig.keptFiles.isEmpty)
    }

    /// No size cap (Leo, 2026-10-26: "I ALREADY SAID WE NEED ARBITARRILY LARGE FILES OF ANY TYPE"):
    /// a recording past the old 1 GiB limit is kept whole, as a clone, never read into memory.
    @Test func aPreviewOfAnySizeIsKeptAndAMissingOneNeverBecomesADeadLink() async throws {
        let source = try Self.preview(data: Data("movie".utf8))
        let saved = try Self.folder("recording-large")
        defer {
            try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: saved)
        }
        let rig = Rig(saved: saved)
        let large = 3 * 1024 * 1024 * 1024 + 7
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: UInt64(large))
        try handle.close()
        rig.model.droppedPaths.stash([source], kind: .drop)
        try FileManager.default.removeItem(at: source.deletingLastPathComponent())
        let kept = try #require(Self.paths(await rig.ask([source.lastPathComponent])).first)
        let size = try FileManager.default.attributesOfItem(atPath: kept)[.size] as? Int
        #expect(size == large)

        let gone = try Self.preview(data: Data("movie".utf8))
        defer { try? FileManager.default.removeItem(at: gone.deletingLastPathComponent()) }
        try FileManager.default.removeItem(at: gone)
        rig.model.droppedPaths.stash([gone], kind: .drop)
        #expect(Self.paths(await rig.ask([gone.lastPathComponent])).isEmpty)
    }

    /// A screenshot from the same floating preview is kept too: its original uploaded after its
    /// preview was read, from a file macOS had already removed (its tile's Retry, Leo 2026-10-31).
    @Test func aScreenshotPreviewIsKeptAsARecordingIs() async throws {
        let data = Data([0x89, 0x50, 0x4e, 0x47])
        let source = try Self.preview("Screenshot.png", data: data)
        let saved = try Self.folder("screenshot-saved")
        defer {
            try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: saved)
        }
        let rig = Rig(saved: saved)
        rig.model.droppedPaths.stash([source], kind: .drop)
        try FileManager.default.removeItem(at: source.deletingLastPathComponent())
        let kept = URL(fileURLWithPath: try #require(Self.paths(await rig.ask([source.lastPathComponent])).first))
        #expect(kept.lastPathComponent == "Screenshot.png")
        #expect(try Data(contentsOf: kept) == data)
    }

    @Test func aFailedSaveNeverReturnsTheTemporaryPath() async throws {
        let source = try Self.preview(data: Data("movie".utf8))
        let saved = try Self.folder("recording-refused")
        defer {
            try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: saved)
        }
        let rig = Rig(saved: saved)
        // A root under a plain file: no folder can be made there.
        let blocked = saved.appendingPathComponent("file")
        try Data("x".utf8).write(to: blocked)
        rig.model.chatUploadFolders = ChatUploadFolders(root: blocked.appendingPathComponent("root"))
        rig.model.droppedPaths.stash([source], kind: .drop)
        #expect(Self.paths(await rig.ask([source.lastPathComponent])).isEmpty)
    }

    @Test func aRetainedRecordingCannotCrossChatsWhenThePaneAdoptsAnotherSession() async throws {
        let source = try Self.preview(data: Data("movie".utf8))
        let saved = try Self.folder("recording-session-scope")
        defer {
            try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: saved)
        }
        let rig = Rig(saved: saved)
        rig.model.adoptSession("chat-a")
        rig.model.droppedPaths.stash([source], kind: .drop)
        let kept = URL(fileURLWithPath: try #require(Self.paths(await rig.ask([source.lastPathComponent])).first))
        rig.model.adoptSession("chat-b")
        let refused = await rig.model.respond(to: AgentPaneRequest(body: ["method": "file.drag", "params": ["path": kept.path]]))
        #expect(refused["ok"] as? Bool == false)
        #expect(rig.dragged.isEmpty)
    }

    @Test func aPendingRecordingCannotBeConsumedByTheNextChat() async throws {
        let source = try Self.preview(data: Data("movie".utf8))
        let saved = try Self.folder("recording-pending-session-scope")
        defer {
            try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: saved)
        }
        let rig = Rig(saved: saved)
        rig.model.adoptSession("chat-a")
        rig.model.droppedPaths.stash([source], kind: .drop)
        rig.model.adoptSession("chat-b")
        #expect(Self.paths(await rig.ask([source.lastPathComponent])).isEmpty)
        #expect(rig.keptFiles.isEmpty)
    }

    @Test func firstSessionAdoptionPreservesPendingAndRetainedRecordings() async throws {
        let retainedSource = try Self.preview("retained.mov", data: Data("retained".utf8))
        let pendingSource = try Self.preview("pending.mov", data: Data("pending".utf8))
        let saved = try Self.folder("recording-first-session")
        defer {
            try? FileManager.default.removeItem(at: retainedSource.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: pendingSource.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: saved)
        }
        let rig = Rig(saved: saved)
        rig.model.droppedPaths.stash([retainedSource], kind: .drop)
        let retainedPath = URL(fileURLWithPath: try #require(Self.paths(await rig.ask([retainedSource.lastPathComponent])).first))
        rig.model.droppedPaths.stash([pendingSource], kind: .drop)
        rig.model.adoptSession("chat-a")
        let pendingPath = URL(fileURLWithPath: try #require(Self.paths(await rig.ask([pendingSource.lastPathComponent])).first))

        for path in [retainedPath, pendingPath] {
            let reply = await rig.model.respond(to: AgentPaneRequest(body: [
                "method": "file.drag", "params": ["path": path.path],
            ]))
            #expect(reply["ok"] as? Bool == true)
        }
    }
}
