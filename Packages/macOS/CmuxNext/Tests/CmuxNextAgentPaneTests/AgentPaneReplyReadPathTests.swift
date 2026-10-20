import Darwin
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// `link.readPath` (labs chatViewer, Lucas 2026-10-19): a path chip's file as text for the chat's
/// viewer, behind the same checks as `link.openPath`.
struct AgentPaneReplyReadPathTests {
    @Test func refusesAFinalComponentSwappedToAnOutsideSymlink() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("read-symlink-\(UUID().uuidString)")
        let root = folder.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let note = root.appendingPathComponent("note.txt")
        let outside = folder.appendingPathComponent("outside.txt")
        try Data("safe".utf8).write(to: note)
        try Data("outside".utf8).write(to: outside)
        let paths = AgentPaneReplyPaths(roots: [root.path], home: folder.path, base: root.path)
        let checked = try #require(paths.resolve(note.path))
        #expect(checked.place == .root)

        try FileManager.default.removeItem(at: note)
        try FileManager.default.createSymbolicLink(at: note, withDestinationURL: outside)

        #expect(AgentPaneReplyRequest.FileText(path: checked.path, paths: paths, outsideRootsAllowed: true) == nil)
    }

    @Test func refusesAnOpenedDescriptorRedirectedIntoADeniedFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("read-ancestor-\(UUID().uuidString)")
        let root = folder.appendingPathComponent("project")
        let slot = root.appendingPathComponent("files")
        let denied = folder.appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(at: slot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let note = slot.appendingPathComponent("note.txt")
        let secret = denied.appendingPathComponent("note.txt")
        try Data("safe".utf8).write(to: note)
        try Data("secret".utf8).write(to: secret)
        let paths = AgentPaneReplyPaths(roots: [root.path], home: folder.path, base: root.path)
        let checked = try #require(paths.resolve(note.path))
        #expect(checked.place == .root)

        try FileManager.default.moveItem(at: slot, to: root.appendingPathComponent("original"))
        try FileManager.default.createSymbolicLink(at: slot, withDestinationURL: denied)

        // The final component remains a regular file: only its ancestor is now a symlink.
        #expect(AgentPaneReplyRequest.FileText(path: checked.path, paths: paths, outsideRootsAllowed: true) == nil)
        // Even a matching descriptor path must still pass the deny list.
        let secretPath = secret.resolvingSymlinksInPath().path
        #expect(AgentPaneReplyRequest.FileText(path: secretPath, paths: paths, outsideRootsAllowed: true) == nil)
    }

    @Test func rechecksContainmentAndStillReadsAnAuthorizedFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("read-policy-\(UUID().uuidString)")
        let root = folder.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let note = root.appendingPathComponent("note.txt")
        let outside = folder.appendingPathComponent("outside.txt")
        try Data("hello\n".utf8).write(to: note)
        try Data("outside".utf8).write(to: outside)
        let paths = AgentPaneReplyPaths(roots: [root.path], home: folder.path, base: root.path)
        let checked = try #require(paths.resolve(note.path))
        let read = try #require(AgentPaneReplyRequest.FileText(path: checked.path, paths: paths))
        #expect(read.text == "hello\n")
        #expect(read.bytes == 6)
        #expect(!read.truncated)

        let outsidePath = outside.resolvingSymlinksInPath().path
        #expect(AgentPaneReplyRequest.FileText(path: outsidePath, paths: paths) == nil)
        let allowed = AgentPaneReplyRequest.FileText(path: outsidePath, paths: paths, outsideRootsAllowed: true)
        #expect(allowed?.text == "outside")
    }

    @Test func refusesFifosWithoutWritersAndCharacterDevicesPromptly() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("read-fifo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fifo = folder.appendingPathComponent("pipe").path
        try #require(mkfifo(fifo, mode_t(0o600)) == 0)
        let start = ContinuousClock.now
        #expect(Self.read(path: fifo) == nil)
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(Self.read(path: "/dev/null") == nil)
        #expect(Self.read(path: "/dev/zero") == nil)
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

        let read = try #require(Self.read(path: file.path))
        #expect(read.text == "")
        #expect(read.bytes == 0)
        #expect(!read.truncated)
    }

    @Test(arguments: ["pdf", "PDF"])
    func leavesAnASCIIOnlyPDFToTheTab(extension suffix: String) throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ascii-\(UUID().uuidString).\(suffix)")
        defer { try? FileManager.default.removeItem(at: file) }
        // A valid blank page, including an xref table, with no binary marker or NUL bytes.
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << >> >>",
        ]
        var pdf = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = pdf.utf8.count
        pdf += "xref\n0 4\n0000000000 65535 f \n"
        for offset in offsets { pdf += String(format: "%010d 00000 n \n", offset) }
        pdf += "trailer\n<< /Size 4 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        let data = Data(pdf.utf8)
        #expect(data.allSatisfy { $0 > 0 && $0 < 128 })
        try data.write(to: file)

        let read = try #require(Self.read(path: file.path))
        #expect(read.text == nil)
        #expect(read.bytes == data.count)
        #expect(!read.truncated)
    }

    @Test(arguments: ["svg", "png", "zip", "tar", "mp4", "mp3", "ttf"])
    func leavesKnownNonTextTypesToTheTab(extension suffix: String) throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("typed-\(UUID().uuidString).\(suffix)")
        defer { try? FileManager.default.removeItem(at: file) }
        let data = Data("ASCII-only payload".utf8)
        try data.write(to: file)

        let read = try #require(Self.read(path: file.path))
        #expect(read.text == nil)
        #expect(read.bytes == data.count)
        #expect(!read.truncated)
    }

    @Test func readsTextCutsLongFilesAndLeavesBinaryToTheTab() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("read-path-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let note = folder.appendingPathComponent("note.txt")
        try Data("hello\n".utf8).write(to: note)
        let read = Self.read(path: note.path)
        #expect(read?.text == "hello\n")
        #expect(read?.bytes == 6)
        #expect(read?.truncated == false)

        let limit = AgentPaneReplyRequest.FileText.maximumBytes
        let long = folder.appendingPathComponent("long.txt")
        try Data(repeating: 0x61, count: limit + 10).write(to: long)
        let cut = Self.read(path: long.path)
        #expect(cut?.truncated == true)
        #expect(cut?.bytes == limit + 10)
        #expect(cut?.text?.utf8.count == limit)

        let image = folder.appendingPathComponent("image.png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01]).write(to: image)
        let binary = Self.read(path: image.path)
        #expect(binary != nil)
        #expect(binary?.text == nil)

        let empty = folder.appendingPathComponent("empty.txt")
        try Data().write(to: empty)
        #expect(Self.read(path: empty.path)?.text == "")

        #expect(Self.read(path: folder.appendingPathComponent("missing.txt").path) == nil)
    }

    private static func read(path: String) -> AgentPaneReplyRequest.FileText? {
        let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let parent = (canonical as NSString).deletingLastPathComponent
        let paths = AgentPaneReplyPaths(roots: [parent], base: parent)
        return AgentPaneReplyRequest.FileText(path: canonical, paths: paths)
    }

}
