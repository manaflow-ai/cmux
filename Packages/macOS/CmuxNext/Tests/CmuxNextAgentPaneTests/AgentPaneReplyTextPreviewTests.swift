@testable import CmuxNextAgentPane
import CmuxNextSettings
import Foundation
import Testing

/// A path chip's hover card shows a text file's first lines (`link.preview`): a bounded read of a
/// regular file, inside the session's folders, or outside them only under
/// `agentPane.links.outsideRoots = open` (a passive hover cannot ask, so `confirm` refuses), never
/// from a deny-listed path, checked again after symlinks and on the open handle.
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

    @Test func aLockedChipOutsideTheFoldersPreviewsUnderOpen() async throws {
        let rig = try Self.rig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        let log = rig.outside.appendingPathComponent("build.log")
        try "started\nok\n".write(to: log, atomically: true, encoding: .utf8)
        rig.model.replyLinks.settings = { AgentPaneReplySetting(outsideRoots: .open, remoteImages: .click) }

        let reply = await rig.preview(log.path)
        #expect(Self.errorCode(reply) == nil, "\(reply)")
        #expect(Self.lines(reply) == ["started", "ok"])
    }

    @Test func confirmAndTextKeepAnOutsideFileUnread() async throws {
        let rig = try Self.rig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        let log = rig.outside.appendingPathComponent("build.log")
        try "secret-ish\n".write(to: log, atomically: true, encoding: .utf8)

        for outsideRoots in [AgentPaneReplySetting.OutsideRoots.confirm, .text] {
            rig.model.replyLinks.settings = { AgentPaneReplySetting(outsideRoots: outsideRoots, remoteImages: .click) }
            let reply = await rig.preview(log.path)
            #expect(Self.errorCode(reply) == AgentPaneReplyError.pathOutsideRoots.rawValue, "\(outsideRoots)")
            #expect(Self.lines(reply) == nil, "\(outsideRoots)")
        }
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

    @Test func aFIFOIsNeverOpenedAndTheHandlesOwnPathIsCheckedAgain() async throws {
        let rig = try Self.rig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        let fifo = rig.project.appendingPathComponent("pipe.log")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let reply = await rig.preview(fifo.path)
        #expect(Self.errorCode(reply) == AgentPaneReplyError.pathInvalid.rawValue, "\(reply)")

        // The open handle's real path goes through `accept` (the deny list and roots again).
        let notes = rig.project.appendingPathComponent("notes.txt")
        try "hi\n".write(to: notes, atomically: true, encoding: .utf8)
        let canonical = try #require(AcpmuxPathPolicy.canonical(notes.path))
        let refused = await AgentPaneReplyTextPreview.read(canonical) { _ in false }
        #expect(refused == .failure(.pathInvalid))
        let seen = await AgentPaneReplyTextPreview.read(canonical) { real in real == canonical }
        #expect(seen == .success(AgentPaneReplyTextPreview(lines: ["hi"], truncated: false)))
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

    @Test func aChatOnAnotherMachineReadsNothingHere() async throws {
        let rig = try Self.rig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        rig.model.replyLinks.settings = { AgentPaneReplySetting(outsideRoots: .open, remoteImages: .click) }
        let inside = rig.project.appendingPathComponent("notes.log")
        try "local secret\n".write(to: inside, atomically: true, encoding: .utf8)
        let outside = rig.outside.appendingPathComponent("notes.log")
        try "local secret\n".write(to: outside, atomically: true, encoding: .utf8)
        rig.model.remoteChat = true

        for url in [inside, outside, rig.outside.appendingPathComponent("gone.log")] {
            let reply = await rig.preview(url.path)
            #expect(Self.errorCode(reply) == nil, "\(url.lastPathComponent): \(reply)")
            #expect(Self.lines(reply) == nil, "\(url.lastPathComponent)")
            #expect((reply["value"] as? [String: Any])?["remote"] as? Bool == true, "\(url.lastPathComponent)")
        }
    }

    /// Counts each time the host looks up this Mac's folders, which every path lookup does first.
    @MainActor private final class Lookups {
        var count = 0
    }

    private static func ask(_ model: AgentPaneModel, _ method: String, _ params: [String: Any]) async -> [String: Any] {
        await model.respond(to: AgentPaneRequest(body: ["method": method, "params": params]))
    }

    /// Counts this Mac's folder lookups on `rig` from now on.
    private static func countLookups(_ rig: Rig) -> Lookups {
        let lookups = Lookups()
        let project = rig.project.path
        rig.model.workspaceRoots = {
            lookups.count += 1
            return [project]
        }
        return lookups
    }

    /// The control for the counter: a chat on this Mac looks its paths up, and gets their places.
    @Test func aLocalChatsInspectLooksItsPathsUp() async throws {
        let rig = try Self.rig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        let lookups = Self.countLookups(rig)
        let notes = rig.project.appendingPathComponent("notes.md")
        try "hi\n".write(to: notes, atomically: true, encoding: .utf8)
        let reply = await Self.ask(rig.model, "link.inspect", ["paths": [notes.path], "urls": [String]()])
        let value = try #require(reply["value"] as? [String: Any], "\(reply)")
        #expect(((value["paths"] as? [String: Any])?[notes.path] as? [String: Any])?["place"] as? String == "root")
        #expect(value["remote"] == nil)
        #expect(lookups.count > 0)
    }

    /// Every path request of a chat on another machine: where its paths are (`link.inspect`), an
    /// image's thumbnail, a video, Open of a file or a folder, the text preview, a file chip's drag
    /// and an image's Reveal. Each is refused before any lookup of the path here (a file of the
    /// same spelling on this Mac is not the agent's), for a secret name and a missing one too.
    private static func expectNothingLooksHere(_ rig: Rig, _ label: String) async throws {
        let lookups = countLookups(rig)
        var dragged: [URL] = []
        var revealed: [URL] = []
        rig.model.replyLinks.mouseHeld = { true }
        rig.model.replyLinks.startDrag = { dragged.append($0); return true }
        rig.model.replyLinks.revealFile = { revealed.append($0) }
        rig.model.replyLinks.imageFolder = rig.folder.appendingPathComponent("copies", isDirectory: true)
        let clip = rig.project.appendingPathComponent("demo.mp4")
        try Data("movie".utf8).write(to: clip)
        let shot = rig.project.appendingPathComponent("shot.png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: shot)
        let sshConfig = rig.home.appendingPathComponent(".ssh/config")
        try "Host *\n".write(to: sshConfig, atomically: true, encoding: .utf8)
        let reports = rig.outside.appendingPathComponent("reports", isDirectory: true)
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)

        for path in [shot.path, sshConfig.path, rig.outside.appendingPathComponent("gone.png").path] {
            let reply = await ask(rig.model, "image.load", ["src": path])
            #expect(errorCode(reply) == AgentPaneReplyError.pathOutsideRoots.rawValue, "\(label) image.load \(path): \(reply)")
            #expect((reply["value"] as? [String: Any])?["src"] == nil, "\(label) image.load \(path)")
        }
        for path in [reports.path + "/", shot.path, sshConfig.path] {
            let reply = await ask(rig.model, "link.openPath", ["path": path])
            #expect(errorCode(reply) == AgentPaneReplyError.pathOutsideRoots.rawValue, "\(label) link.openPath \(path): \(reply)")
        }
        for path in [shot.path, sshConfig.path] {
            let reply = await ask(rig.model, "link.preview", ["path": path])
            #expect((reply["value"] as? [String: Any])?["remote"] as? Bool == true, "\(label) link.preview \(path): \(reply)")
        }
        // The chip stays a chip (no place, so never plain text), and the page learns the chat is remote.
        let inspect = await ask(rig.model, "link.inspect", ["paths": [shot.path, reports.path + "/", sshConfig.path, "/nowhere/gone.txt"], "urls": [String]()])
        let value = try #require(inspect["value"] as? [String: Any], "\(label) link.inspect: \(inspect)")
        #expect((value["paths"] as? [String: Any])?.isEmpty == true, "\(label) link.inspect: \(inspect)")
        #expect(value["remote"] as? Bool == true, "\(label) link.inspect: \(inspect)")
        #expect(value["policy"] != nil, "\(label) link.inspect: \(inspect)")
        for path in [clip.path, sshConfig.path] {
            let reply = await ask(rig.model, "media.load", ["src": path])
            #expect(errorCode(reply) == AgentPaneReplyError.pathOutsideRoots.rawValue, "\(label) media.load \(path): \(reply)")
            #expect((reply["value"] as? [String: Any])?["src"] == nil, "\(label) media.load \(path)")
        }
        for path in [clip.path, reports.path + "/", rig.project.path] {
            let reply = await ask(rig.model, "file.drag", ["path": path])
            #expect(errorCode(reply) != nil, "\(label) file.drag \(path): \(reply)")
        }
        #expect(dragged.isEmpty, "\(label): dragged \(dragged)")
        // Reveal of a remote image shows its copy, never the same-named file here.
        rig.model.transport.gestures.record(click: true)
        let png = "data:image/png;base64," + Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1]).base64EncodedString()
        _ = await ask(rig.model, "image.reveal", ["src": png, "name": "shot", "path": shot.path])
        let shotHere = shot.resolvingSymlinksInPath().path
        #expect(!revealed.contains { $0.resolvingSymlinksInPath().path == shotHere }, "\(label): revealed \(revealed)")
        #expect(lookups.count == 0, "\(label): the host looked up a remote chat's path here")
    }

    @Test func aRemoteChatsImagesAndOpensNeverTouchThisMac() async throws {
        let rig = try Self.rig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        // `open` would show any outside path; a remote chat still gets nothing from this Mac.
        rig.model.replyLinks.settings = { AgentPaneReplySetting(outsideRoots: .open, remoteImages: .click) }
        rig.model.remoteChat = true
        try await Self.expectNothingLooksHere(rig, "remoteChat")
    }

    @Test func aRemoteWireAloneRefusesToo() async throws {
        let rig = try Self.rig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        rig.model.replyLinks.settings = { AgentPaneReplySetting(outsideRoots: .open, remoteImages: .click) }
        // The connection is to another machine's acpmux, before the model has marked the chat remote.
        let wire = AgentPaneRelayedAllowTests.RemoteWire()
        let id = try await rig.model.transport.open(.remote(AgentPaneRemoteRoute(machine: "host") { wire }))
        defer { rig.model.transport.close(connection: id) }
        #expect(rig.model.transport.remoteWire)
        #expect(!rig.model.remoteChat)
        try await Self.expectNothingLooksHere(rig, "remoteWire")
    }

    @Test func aWholeOneLineFileLongerThanTheCapReadsAsCut() {
        let line = String(repeating: "y", count: AgentPaneReplyTextPreview.maximumLineLength + 1)
        let data = Data(line.utf8)
        let preview = AgentPaneReplyTextPreview.text(data, fileSize: data.count)
        let expected = AgentPaneReplyTextPreview(lines: [String(line.prefix(AgentPaneReplyTextPreview.maximumLineLength))], truncated: true)
        #expect(preview == .success(expected))
    }

    @Test func aReadCutInsideACharacterKeepsTheTextBeforeIt() {
        // "é" is two bytes; the read stopped after the first.
        let data = Data("café".utf8).dropLast()
        let preview = AgentPaneReplyTextPreview.text(data, fileSize: 5)
        #expect(preview == .success(AgentPaneReplyTextPreview(lines: ["caf"], truncated: true)))
    }
}
