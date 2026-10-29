import AppKit
@testable import CmuxNextAgentPane
import Foundation
import Testing
import CmuxNextWakeups

/// The user, 2026-10-21: "i need to be able to drag it out to other apps too", and Copy, Save As
/// and Show in Finder for videos and files in agent chats, not only images. A drag that starts on
/// an image or a file chip (or a video's frame) in an agent chat becomes the host's own drag of a
/// real file: the image's named copy, or the file itself when it is inside the chat's folders.
/// Only a press the person holds starts one. A path's menu (a file chip, a video, an audio clip)
/// leads with Copy and Save As…, ahead of Open With, Reveal in Finder and Copy Path.
@MainActor @Suite(.serialized)
struct AgentPaneMediaDragTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
    private static let pngSource = "data:image/png;base64," + png.base64EncodedString()

    private final class Effects {
        var dragged: [URL] = []
        var held = true
        var saved: [(URL, String)] = []
    }

    private static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("media-drag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func model(_ folder: URL) -> (AgentPaneModel, Effects) {
        let model = AgentPaneModel(runner: BackgroundWork(label: "test.agent-pane"), host: NoHost())
        let effects = Effects()
        model.replyLinks.imageFolder = folder.appendingPathComponent("copies", isDirectory: true)
        model.replyLinks.mouseHeld = { effects.held }
        model.replyLinks.startDrag = { effects.dragged.append($0); return true }
        model.replyLinks.saveFile = { effects.saved.append(($0, $1)) }
        return (model, effects)
    }

    private static func ask(_ model: AgentPaneModel, _ method: String, _ params: [String: Any]) async -> [String: Any] {
        await model.respond(to: AgentPaneRequest(body: ["method": method, "params": params]))
    }

    private static func errorCode(_ reply: [String: Any]) -> String? {
        (reply["error"] as? [String: Any])?["code"] as? String
    }

    @Test func draggingAnImageDragsItsNamedCopy() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (model, effects) = Self.model(folder)

        let reply = await Self.ask(model, "image.drag", ["src": Self.pngSource, "name": "chart"])
        #expect(Self.errorCode(reply) == nil, "\(reply)")
        let file = try #require(effects.dragged.first)
        #expect(file.pathExtension == "png")
        #expect(try Data(contentsOf: file) == Self.png)

        // A drag the person is not holding (page script alone) starts nothing.
        effects.held = false
        let unheld = await Self.ask(model, "image.drag", ["src": Self.pngSource, "name": "chart"])
        #expect(Self.errorCode(unheld) == AgentPaneReplyError.gestureRequired.rawValue)
        #expect(effects.dragged.count == 1)
    }

    @Test func draggingAFileChipDragsTheFileInsideTheFoldersOnly() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (model, effects) = Self.model(folder)
        let project = folder.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let clip = project.appendingPathComponent("demo.mp4")
        try Data("movie".utf8).write(to: clip)
        model.workspaceRoots = { [project.path] }

        let reply = await Self.ask(model, "file.drag", ["path": clip.path])
        #expect(Self.errorCode(reply) == nil, "\(reply)")
        #expect(effects.dragged.map { $0.resolvingSymlinksInPath().path } == [clip.resolvingSymlinksInPath().path])

        // Outside the folders, a deny-listed file, or a chat on another machine: no drag.
        let outside = folder.appendingPathComponent("elsewhere.mp4")
        try Data("x".utf8).write(to: outside)
        let refused = await Self.ask(model, "file.drag", ["path": outside.path])
        #expect(Self.errorCode(refused) != nil)
        model.remoteChat = true
        let remote = await Self.ask(model, "file.drag", ["path": clip.path])
        #expect(Self.errorCode(remote) != nil)
        #expect(effects.dragged.count == 1)
    }

    @Test func aFilesMenuLeadsWithCopyAndSaveAs() async throws {
        _ = NSApplication.shared
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clip = folder.appendingPathComponent("demo.mp4")
        try Data("movie".utf8).write(to: clip)
        // Copy's item is recorded, not written (the CI Macs' pasteboard server, HomePasteAnywhereTests).
        var copied: [NSPasteboardItem] = []
        var saved: [(URL, String)] = []
        let rows = AgentPaneFileRows(copyItem: { copied.append($0); return true }, save: { saved.append(($0, $1)) }, runner: BackgroundWork(label: "test.file-rows"))
        let items = rows.items(for: clip)
        #expect(items.map(\.title) == [AgentPaneMenuStrings.copyFile, AgentPaneMenuStrings.saveAs])
        #expect(await rows.copy(clip))
        let item = try #require(copied.first)
        #expect(item.string(forType: .fileURL).flatMap(URL.init(string:))?.standardizedFileURL == clip.standardizedFileURL)
        // A video is offered as its file only, no picture bytes.
        #expect(item.data(forType: .tiff) == nil)
        _ = (items[1].target as? NSObject)?.perform(items[1].action, with: items[1])
        #expect(saved.map(\.1) == ["demo.mp4"])
    }
}
