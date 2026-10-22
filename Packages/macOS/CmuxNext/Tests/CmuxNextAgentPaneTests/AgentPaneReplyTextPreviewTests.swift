@testable import CmuxNextAgentPane
import CmuxNextSettings
import Foundation
import Testing

/// A path chip's hover card shows a text file's first lines (`link.preview`): a bounded read of a
/// regular file, inside the session's folders or outside them (unless
/// `agentPane.links.outsideRoots = text`), never from a deny-listed path, checked again after
/// symlinks.
@MainActor
struct AgentPaneReplyTextPreviewTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @MainActor private struct Rig {
        let model: AgentPaneModel
        let folder: URL
        let home: URL
        let outside: URL
        let project: URL

        func preview(_ path: String) async -> [String: Any] {
            await model.respond(to: AgentPaneRequest(body: ["method": "link.preview", "params": ["path": path]]))
        }
    }

    private static func rig() throws -> Rig {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("reply-text-preview-\(UUID().uuidString)", isDirectory: true)
        let home = folder.appendingPathComponent("home", isDirectory: true)
        let outside = folder.appendingPathComponent("tmp-logs", isDirectory: true)
        let project = home.appendingPathComponent("project", isDirectory: true)
        for directory in [home, outside, project, home.appendingPathComponent(".ssh", isDirectory: true)] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let model = AgentPaneModel(host: NoHost())
        model.workspaceRoots = { [project.path] }
        model.replyLinks.home = home.path
        return Rig(model: model, folder: folder, home: home, outside: outside, project: project)
    }

    private static func errorCode(_ reply: [String: Any]) -> String? {
        (reply["error"] as? [String: Any])?["code"] as? String
    }

    private static func lines(_ reply: [String: Any]) -> [String]? {
        (reply["value"] as? [String: Any])?["lines"] as? [String]
    }

    private static func truncated(_ reply: [String: Any]) -> Bool? {
        (reply["value"] as? [String: Any])?["truncated"] as? Bool
    }

    @Test func theRequestTakesOnlyAPathAndIsPassive() {
        let request = AgentPaneReplyRequest(method: "link.preview", params: ["path": "/tmp/a.log"])
        #expect(request == .previewPath("/tmp/a.log"))
        #expect(request?.isPassive == true)
        #expect(AgentPaneReplyRequest.methods.contains("link.preview"))
        #expect(AgentPaneReplyRequest(method: "link.preview", params: ["path": "/tmp/a.log", "lines": 400]) == nil)
        #expect(AgentPaneReplyRequest(method: "link.preview", params: [:]) == nil)
        #expect(AgentPaneReplyRequest(method: "link.preview", params: ["path": ""]) == nil)
    }

    @Test func aFileInTheProjectShowsItsFirstFortyLines() async throws {
        let rig = try Self.rig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        let notes = rig.project.appendingPathComponent("NOTES.md")
        try (1...100).map { "line \($0)" }.joined(separator: "\n").write(to: notes, atomically: true, encoding: .utf8)

        let reply = await rig.preview(notes.path)
        #expect(Self.errorCode(reply) == nil, "\(reply)")
        #expect(Self.lines(reply) == (1...40).map { "line \($0)" })
        #expect(Self.truncated(reply) == true)

        let short = rig.project.appendingPathComponent("short.txt")
        try "one\r\ntwo\n".write(to: short, atomically: true, encoding: .utf8)
        let whole = await rig.preview(short.path)
        #expect(Self.lines(whole) == ["one", "two"])
        #expect(Self.truncated(whole) == false)
    }

    @Test func aLockedChipOutsideTheFoldersPreviewsUnderOpenAndConfirm() async throws {
        let rig = try Self.rig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        let log = rig.outside.appendingPathComponent("build.log")
        try "started\nok\n".write(to: log, atomically: true, encoding: .utf8)

        for outsideRoots in [AgentPaneReplySetting.OutsideRoots.open, .confirm] {
            rig.model.replyLinks.settings = { AgentPaneReplySetting(outsideRoots: outsideRoots, remoteImages: .click) }
            let reply = await rig.preview(log.path)
            #expect(Self.errorCode(reply) == nil, "\(outsideRoots): \(reply)")
            #expect(Self.lines(reply) == ["started", "ok"], "\(outsideRoots)")
        }
    }

    @Test func outsideRootsTextTurnsTheOutsidePreviewOff() async throws {
        let rig = try Self.rig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        let log = rig.outside.appendingPathComponent("build.log")
        try "secret-ish\n".write(to: log, atomically: true, encoding: .utf8)
        rig.model.replyLinks.settings = { AgentPaneReplySetting(outsideRoots: .text, remoteImages: .click) }

        let reply = await rig.preview(log.path)
        #expect(Self.errorCode(reply) == AgentPaneReplyError.pathOutsideRoots.rawValue)
        #expect(Self.lines(reply) == nil)
    }

    @Test func aDenyListedFileIsNeverRead() async throws {
        let rig = try Self.rig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        rig.model.replyLinks.settings = { AgentPaneReplySetting(outsideRoots: .open, remoteImages: .click) }
        let sshConfig = rig.home.appendingPathComponent(".ssh/config")
        try "Host *\n".write(to: sshConfig, atomically: true, encoding: .utf8)
        let env = rig.project.appendingPathComponent(".env.local")
        try "TOKEN=abc\n".write(to: env, atomically: true, encoding: .utf8)
        // Harmless names, inside and outside the folders, that point at the secret.
        let inside = rig.project.appendingPathComponent("readme.txt")
        try FileManager.default.createSymbolicLink(at: inside, withDestinationURL: sshConfig)
        let outsideLink = rig.outside.appendingPathComponent("notes.txt")
        try FileManager.default.createSymbolicLink(at: outsideLink, withDestinationURL: env)

        for url in [sshConfig, env, inside, outsideLink] {
            let reply = await rig.preview(url.path)
            #expect(Self.errorCode(reply) == AgentPaneReplyError.pathDenied.rawValue, "\(url.lastPathComponent): \(reply)")
            #expect(Self.lines(reply) == nil)
        }
    }

    @Test func onlyRegularTextFilesAreRead() async throws {
        let rig = try Self.rig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        let binary = rig.project.appendingPathComponent("blob.bin")
        try Data([0x41, 0x00, 0x42]).write(to: binary)
        let notUTF8 = rig.project.appendingPathComponent("latin.txt")
        try Data([0x66, 0xFF, 0xFE, 0x6F]).write(to: notUTF8)
        let folder = rig.project.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let missing = rig.project.appendingPathComponent("gone.txt")

        for url in [binary, notUTF8, folder, missing] {
            let reply = await rig.preview(url.path)
            #expect(Self.errorCode(reply) == AgentPaneReplyError.pathInvalid.rawValue, "\(url.lastPathComponent): \(reply)")
            #expect(Self.lines(reply) == nil)
        }
        // Outside the folders, every refusal reads the same.
        let outsideBinary = rig.outside.appendingPathComponent("core.bin")
        try Data([0x00, 0x01]).write(to: outsideBinary)
        for url in [outsideBinary, rig.outside.appendingPathComponent("gone.log"), rig.outside] {
            let reply = await rig.preview(url.path)
            #expect(Self.errorCode(reply) == AgentPaneReplyError.pathOutsideRoots.rawValue, "\(url.lastPathComponent): \(reply)")
        }
    }

    @Test func aHugeFileReadsOnlyItsFirstBytesAndCutsLongLines() async throws {
        let rig = try Self.rig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        let huge = rig.project.appendingPathComponent("huge.log")
        // 4 MB on one line, then more lines the preview never reaches.
        let line = String(repeating: "x", count: 4 << 20)
        try (line + "\nnext\n").write(to: huge, atomically: true, encoding: .utf8)

        let reply = await rig.preview(huge.path)
        let lines = try #require(Self.lines(reply), "\(reply)")
        #expect(lines.count == 1)
        #expect(lines[0].count == AgentPaneReplyTextPreview.maximumLineLength)
        #expect(Self.truncated(reply) == true)
    }

    @Test func aReadCutInsideACharacterKeepsTheTextBeforeIt() {
        // "é" is two bytes; the read stopped after the first.
        let data = Data("café".utf8).dropLast()
        let preview = AgentPaneReplyTextPreview.text(data, fileSize: 5)
        #expect(preview == .success(AgentPaneReplyTextPreview(lines: ["caf"], truncated: true)))
    }
}
