import Darwin
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// `link.readPath` (labs chatViewer, Lucas 2026-10-19): a path chip's file as text for the chat's
/// viewer, behind the same checks as `link.openPath`.
struct AgentPaneReplyReadPathTests {
    @Test func refusesFifosWithoutWritersAndCharacterDevicesPromptly() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("read-fifo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fifo = folder.appendingPathComponent("pipe").path
        try #require(mkfifo(fifo, mode_t(0o600)) == 0)
        let start = ContinuousClock.now
        #expect(AgentPaneReplyRequest.FileText(path: fifo) == nil)
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(AgentPaneReplyRequest.FileText(path: "/dev/null") == nil)
        #expect(AgentPaneReplyRequest.FileText(path: "/dev/zero") == nil)
    }

    @Test func takesOnlyItsPathAndSpendsAGesture() {
        #expect(AgentPaneReplyRequest(method: "link.readPath", params: ["path": "src/App.tsx"]) == .readPath("src/App.tsx"))
        #expect(AgentPaneReplyRequest(method: "link.readPath", params: ["path": "src/App.tsx", "extra": "x"]) == nil)
        #expect(AgentPaneReplyRequest(method: "link.readPath", params: [:]) == nil)
        #expect(AgentPaneReplyRequest.methods.contains("link.readPath"))
        #expect(!AgentPaneReplyRequest.readPath("src/App.tsx").isPassive)
    }

    @Test func opensAnEmptyTextFileWithoutTruncation() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("empty-\(UUID().uuidString).txt")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let read = try #require(AgentPaneReplyRequest.FileText(path: file.path))
        #expect(read.text == "")
        #expect(read.bytes == 0)
        #expect(!read.truncated)
    }

    @Test func readsTextCutsLongFilesAndLeavesBinaryToTheTab() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("read-path-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let note = folder.appendingPathComponent("note.txt")
        try Data("hello\n".utf8).write(to: note)
        let read = AgentPaneReplyRequest.FileText(path: note.path)
        #expect(read?.text == "hello\n")
        #expect(read?.bytes == 6)
        #expect(read?.truncated == false)

        let limit = AgentPaneReplyRequest.FileText.maximumBytes
        let long = folder.appendingPathComponent("long.txt")
        try Data(repeating: 0x61, count: limit + 10).write(to: long)
        let cut = AgentPaneReplyRequest.FileText(path: long.path)
        #expect(cut?.truncated == true)
        #expect(cut?.bytes == limit + 10)
        #expect(cut?.text?.utf8.count == limit)

        let image = folder.appendingPathComponent("image.png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01]).write(to: image)
        let binary = AgentPaneReplyRequest.FileText(path: image.path)
        #expect(binary != nil)
        #expect(binary?.text == nil)

        let empty = folder.appendingPathComponent("empty.txt")
        try Data().write(to: empty)
        #expect(AgentPaneReplyRequest.FileText(path: empty.path)?.text == "")

        #expect(AgentPaneReplyRequest.FileText(path: folder.appendingPathComponent("missing.txt").path) == nil)
    }
}
