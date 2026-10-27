@testable import CmuxNextAgentPane
import CmuxNextSettings
import Darwin
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

        // A file this user can't read: refused, never an error that says more.
        let locked = rig.project.appendingPathComponent("locked.log")
        try "secret\n".write(to: locked, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: locked.path) }

        for url in [binary, notUTF8, folder, missing, locked] {
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
        // Marked remote by the model, or only by its connection to another machine's acpmux.
        for wireOnly in [false, true] {
            let rig = try Self.rig()
            defer { try? FileManager.default.removeItem(at: rig.folder) }
            rig.model.replyLinks.settings = { AgentPaneReplySetting(outsideRoots: .open, remoteImages: .click) }
            // Every path lookup reads the folders first; a remote chat's preview must not.
            var lookups = 0
            let project = rig.project.path
            rig.model.workspaceRoots = {
                lookups += 1
                return [project]
            }
            let inside = rig.project.appendingPathComponent("notes.log")
            try "local secret\n".write(to: inside, atomically: true, encoding: .utf8)
            let outside = rig.outside.appendingPathComponent("notes.log")
            try "local secret\n".write(to: outside, atomically: true, encoding: .utf8)
            var connection: Int?
            if wireOnly {
                let wire = AgentPaneRelayedAllowTests.RemoteWire()
                connection = try await rig.model.transport.open(.remote(AgentPaneRemoteRoute(machine: "host") { wire }))
                #expect(rig.model.transport.remoteWire && !rig.model.remoteChat)
            } else {
                rig.model.remoteChat = true
            }
            for url in [inside, outside, rig.outside.appendingPathComponent("gone.log")] {
                let reply = await rig.preview(url.path)
                #expect(Self.errorCode(reply) == nil, "\(wireOnly) \(url.lastPathComponent): \(reply)")
                #expect(Self.lines(reply) == nil, "\(wireOnly) \(url.lastPathComponent)")
                #expect((reply["value"] as? [String: Any])?["remote"] as? Bool == true, "\(wireOnly) \(url.lastPathComponent)")
            }
            #expect(lookups == 0, "\(wireOnly): the host looked up a remote chat's path here")
            if let connection { rig.model.transport.close(connection: connection) }
        }
    }

    /// The read runs off the main actor; a chat that turns remote while it runs gets none of this
    /// Mac's lines, only `{remote: true}`, and a chat that stays local still gets them.
    @Test func aReadThatOutlivesTheChatTurningRemoteSendsNothing() async throws {
        for wireOnly in [false, true] {
            let rig = try Self.rig()
            defer { try? FileManager.default.removeItem(at: rig.folder) }
            let notes = rig.project.appendingPathComponent("notes.log")
            try "local secret\n".write(to: notes, atomically: true, encoding: .utf8)
            let local = await rig.preview(notes.path)
            #expect(Self.lines(local) == ["local secret"], "\(wireOnly): \(local)")

            let model = rig.model
            let opened = Opened()
            rig.model.replyLinks.readTextPreview = { path, accept in
                await Self.turnRemote(model, wireOnly: wireOnly, into: opened)
                return await AgentPaneReplyTextPreview.read(path, accept: accept)
            }
            let reply = await rig.preview(notes.path)
            #expect(Self.errorCode(reply) == nil, "\(wireOnly): \(reply)")
            #expect(Self.lines(reply) == nil, "\(wireOnly): \(reply)")
            #expect((reply["value"] as? [String: Any])?["remote"] as? Bool == true, "\(wireOnly): \(reply)")
            if let connection = opened.connection { rig.model.transport.close(connection: connection) }
        }
    }

    @MainActor private final class Opened {
        var connection: Int?
    }

    private static func turnRemote(_ model: AgentPaneModel, wireOnly: Bool, into opened: Opened) async {
        guard wireOnly else {
            model.remoteChat = true
            return
        }
        let wire = AgentPaneRelayedAllowTests.RemoteWire()
        opened.connection = try? await model.transport.open(.remote(AgentPaneRemoteRoute(machine: "host") { wire }))
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
