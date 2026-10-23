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
        var uploads: [AgentPaneUpload] = []
        var dragged: [URL] = []
        let saved: URL

        init(saved: URL) {
            self.saved = saved
            let clock = clock
            model.droppedPaths = AgentPaneDroppedPaths(now: { clock.now })
            model.onLocalPaths = { true }
            model.replyLinks.mouseHeld = { true }
            model.replyLinks.startDrag = { [weak self] in self?.dragged.append($0); return true }
            model.onUpload = { [weak self] in
                guard let self else { return nil }
                return { files in
                    self.uploads += files
                    let saved = self.saved
                    let paths = try? await Task.detached {
                        try files.enumerated().map { index, file in
                            let folder = saved.appendingPathComponent(String(index), isDirectory: true)
                            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                            let target = folder.appendingPathComponent(file.name)
                            try file.data.write(to: target)
                            return target.path
                        }
                    }.value
                    guard let paths else { return AgentPaneReply.failure(code: "upload_failed", message: "Not saved") }
                    return AgentPaneReply.success(["uploads": paths.map { ["path": $0] }])
                }
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
        #expect(rig.uploads.map(\.data) == [data])

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
        #expect(rig.uploads.isEmpty)
    }

    @Test func missingOrOversizedPreviewsNeverBecomeDeadLinks() async throws {
        let source = try Self.preview(data: Data("movie".utf8))
        let saved = try Self.folder("recording-unavailable")
        defer {
            try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: saved)
        }
        let rig = Rig(saved: saved)
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: UInt64(AgentPaneUpload.maximumFileBytes + 1))
        try handle.close()
        rig.model.droppedPaths.stash([source], kind: .drop)
        #expect(Self.paths(await rig.ask([source.lastPathComponent])).isEmpty)
        try FileManager.default.removeItem(at: source)
        rig.model.droppedPaths.stash([source], kind: .drop)
        #expect(Self.paths(await rig.ask([source.lastPathComponent])).isEmpty)
        #expect(rig.uploads.isEmpty)
    }

    @Test func aFailedSaveNeverReturnsTheTemporaryPath() async throws {
        let source = try Self.preview(data: Data("movie".utf8))
        let saved = try Self.folder("recording-refused")
        defer {
            try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: saved)
        }
        let rig = Rig(saved: saved)
        rig.model.onUpload = { { _ in AgentPaneReply.failure(code: "upload_failed", message: "Not saved") } }
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
}
