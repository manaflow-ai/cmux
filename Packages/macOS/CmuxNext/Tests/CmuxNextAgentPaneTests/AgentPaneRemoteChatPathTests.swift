@testable import CmuxNextAgentPane
@testable import CmuxNextPages
import CmuxNextSettings
import Foundation
import AppKit
import Testing

/// A chat on another machine never touches this Mac's files (cx-k21v): its agent names paths on
/// that machine, and a path here with the same spelling is not its file. Every path request the
/// page makes for such a chat (where its paths are, an image's thumbnail, a video, Open of a file
/// or a folder, a file chip's drag, an image's Reveal) is refused before any lookup of the path
/// here, whether the model has marked the chat remote or only its connection is.
@MainActor @Suite(.serialized)
struct AgentPaneRemoteChatPathTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// Counts each time the host looks up this Mac's folders, which every path lookup does first.
    @MainActor private final class Lookups {
        var count = 0
    }

    @MainActor private struct Rig {
        let model: AgentPaneModel
        let folder: URL
        let home: URL
        let outside: URL
        let project: URL
        let lookups = Lookups()
    }

    private static func rig() throws -> Rig {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-chat-paths-\(UUID().uuidString)", isDirectory: true)
        let home = folder.appendingPathComponent("home", isDirectory: true)
        let outside = folder.appendingPathComponent("tmp-logs", isDirectory: true)
        let project = home.appendingPathComponent("project", isDirectory: true)
        for directory in [home, outside, project, home.appendingPathComponent(".ssh", isDirectory: true)] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let model = AgentPaneModel(host: NoHost())
        model.replyLinks.home = home.path
        // `open` would show any outside path; a remote chat still gets nothing from this Mac.
        model.replyLinks.settings = { AgentPaneReplySetting(outsideRoots: .open, remoteImages: .click) }
        let rig = Rig(model: model, folder: folder, home: home, outside: outside, project: project)
        let lookups = rig.lookups
        let projectPath = project.path
        model.workspaceRoots = {
            lookups.count += 1
            return [projectPath]
        }
        return rig
    }

    private static func ask(_ model: AgentPaneModel, _ method: String, _ params: [String: Any]) async -> [String: Any] {
        await model.respond(to: AgentPaneRequest(body: ["method": method, "params": params]))
    }

    private static func errorCode(_ reply: [String: Any]) -> String? {
        (reply["error"] as? [String: Any])?["code"] as? String
    }

    /// The control for the counter: a chat on this Mac looks its paths up, and gets their places.
    @Test func aLocalChatsInspectLooksItsPathsUp() async throws {
        let rig = try Self.rig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        let notes = rig.project.appendingPathComponent("notes.md")
        try "hi\n".write(to: notes, atomically: true, encoding: .utf8)
        let reply = await Self.ask(rig.model, "link.inspect", ["paths": [notes.path], "urls": [String]()])
        let value = try #require(reply["value"] as? [String: Any], "\(reply)")
        #expect(((value["paths"] as? [String: Any])?[notes.path] as? [String: Any])?["place"] as? String == "root")
        #expect(rig.lookups.count > 0)
    }

    /// Every path request of a remote chat, for a project file, a secret name, a folder and a
    /// missing path: refused, and no lookup of any of them here.
    private static func expectNothingLooksHere(_ rig: Rig, _ label: String) async throws {
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

        // The chip stays a chip (no place, so never plain text). A chat the model has marked
        // remote keeps its raster image's place: that image loads from its own machine.
        let inspect = await ask(rig.model, "link.inspect", ["paths": [shot.path, reports.path + "/", sshConfig.path, "/nowhere/gone.txt"], "urls": [String]()])
        let value = try #require(inspect["value"] as? [String: Any], "\(label) link.inspect: \(inspect)")
        let places = try #require(value["paths"] as? [String: Any], "\(label) link.inspect: \(inspect)")
        #expect(Set(places.keys) == (rig.model.remoteChat ? [shot.path] : []), "\(label) link.inspect: \(inspect)")
        #expect(value["policy"] != nil, "\(label) link.inspect: \(inspect)")
        // No remote image loader here: a remote chat's image is refused, never read on this Mac.
        let refused = [AgentPaneReplyError.pathOutsideRoots.rawValue, AgentPaneReplyError.imageRefused.rawValue]
        for path in [shot.path, sshConfig.path, rig.outside.appendingPathComponent("gone.png").path] {
            let reply = await ask(rig.model, "image.load", ["src": path])
            #expect(errorCode(reply).map(refused.contains) == true, "\(label) image.load \(path): \(reply)")
        }
        for path in [clip.path, sshConfig.path] {
            let reply = await ask(rig.model, "media.load", ["src": path])
            #expect(errorCode(reply) == AgentPaneReplyError.pathOutsideRoots.rawValue, "\(label) media.load \(path): \(reply)")
        }
        for path in [reports.path + "/", shot.path, sshConfig.path] {
            let reply = await ask(rig.model, "link.openPath", ["path": path])
            #expect(errorCode(reply) == AgentPaneReplyError.pathOutsideRoots.rawValue, "\(label) link.openPath \(path): \(reply)")
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
        #expect(rig.lookups.count == 0, "\(label): the host looked up a remote chat's path here")
    }

    @Test func aRemoteChatsPathsNeverTouchThisMac() async throws {
        let rig = try Self.rig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        rig.model.remoteChat = true
        try await Self.expectNothingLooksHere(rig, "remoteChat")
    }

    @Test func aRemoteWireAloneRefusesToo() async throws {
        let rig = try Self.rig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        // The connection is to another machine's acpmux, before the model has marked the chat remote.
        let wire = AgentPaneRelayedAllowTests.RemoteWire()
        let id = try await rig.model.transport.open(.remote(AgentPaneRemoteRoute(machine: "host") { wire }))
        defer { rig.model.transport.close(connection: id) }
        #expect(rig.model.transport.remoteWire)
        #expect(!rig.model.remoteChat)
        try await Self.expectNothingLooksHere(rig, "remoteWire")
    }

    /// How a chat turns remote mid-request: the model marks it, or only its connection does.
    private static func turnRemote(_ rig: Rig, wireOnly: Bool) async throws -> Int? {
        try await turnRemote(rig.model, wireOnly: wireOnly)
    }

    private static func turnRemote(_ model: AgentPaneModel, wireOnly: Bool) async throws -> Int? {
        guard wireOnly else {
            model.remoteChat = true
            return nil
        }
        let wire = AgentPaneRelayedAllowTests.RemoteWire()
        return try await model.transport.open(.remote(AgentPaneRemoteRoute(machine: "host") { wire }))
    }

    /// Open of an outside path waits on the person's confirmation; a chat that turns remote while
    /// the sheet is up opens nothing here when the answer comes.
    @Test func aChatThatTurnsRemoteDuringTheConfirmationOpensNothing() async throws {
        for wireOnly in [false, true] {
            for folder in [false, true] {
                let rig = try Self.rig()
                defer { try? FileManager.default.removeItem(at: rig.folder) }
                rig.model.replyLinks.settings = { AgentPaneReplySetting(outsideRoots: .confirm, remoteImages: .click) }
                let target = rig.outside.appendingPathComponent(folder ? "reports" : "build.log", isDirectory: folder)
                if folder {
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                } else {
                    try "ok\n".write(to: target, atomically: true, encoding: .utf8)
                }
                var opened: [URL] = []
                rig.model.onOpenFile = { url, _, _ in opened.append(url); return true }
                rig.model.replyLinks.revealFolder = { opened.append($0) }
                var connection: Int?
                rig.model.replyLinks.confirmOutside = { _, answer in
                    // task-owner: test; turns the chat remote while the sheet is up, then answers Open
                    Task { @MainActor in
                        connection = try? await Self.turnRemote(rig, wireOnly: wireOnly)
                        answer(true)
                    }
                }
                rig.model.transport.gestures.record(click: true)
                let path = folder ? target.path + "/" : target.path
                let reply = await Self.ask(rig.model, "link.openPath", ["path": path])
                #expect(Self.errorCode(reply) == AgentPaneReplyError.pathOutsideRoots.rawValue, "\(wireOnly) \(path): \(reply)")
                #expect(opened.isEmpty, "\(wireOnly) \(path): opened \(opened)")
                if let connection { rig.model.transport.close(connection: connection) }
            }
        }
    }

    /// The control: the same confirmed Open in a chat that stays on this Mac opens the file.
    @Test func aConfirmedOpenInALocalChatOpensTheFile() async throws {
        let rig = try Self.rig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        rig.model.replyLinks.settings = { AgentPaneReplySetting(outsideRoots: .confirm, remoteImages: .click) }
        let log = rig.outside.appendingPathComponent("build.log")
        try "ok\n".write(to: log, atomically: true, encoding: .utf8)
        var opened: [URL] = []
        rig.model.onOpenFile = { url, _, _ in opened.append(url); return true }
        rig.model.replyLinks.confirmOutside = { _, answer in answer(true) }
        rig.model.transport.gestures.record(click: true)
        let reply = await Self.ask(rig.model, "link.openPath", ["path": log.path])
        #expect(Self.errorCode(reply) == nil, "\(reply)")
        #expect(opened.map { $0.resolvingSymlinksInPath().path } == [log.resolvingSymlinksInPath().path])
    }

    /// A pane on a page that never loads anything (the menu needs only the view and its model).
    private static func view(_ rig: Rig) throws -> AgentPaneView {
        let page = rig.folder.appendingPathComponent("index.html")
        try Data("<html><body></body></html>".utf8).write(to: page)
        return try #require(AgentPaneView(model: rig.model, source: .bundled(page)))
    }

    /// Runs a menu item's action as AppKit does.
    private static func run(_ item: NSMenuItem) {
        _ = (item.target as? NSObject)?.perform(item.action, with: item)
    }

    /// A path's menu built while the chat was on this Mac: once the chat turns remote, its rows
    /// act on nothing here, whatever they held when the menu opened.
    @Test func aPathMenuThatOutlivesTheChatTurningRemoteDoesNothing() async throws {
        for wireOnly in [false, true] {
            let rig = try Self.rig()
            defer { try? FileManager.default.removeItem(at: rig.folder) }
            let notes = rig.project.appendingPathComponent("notes.md")
            try "hi\n".write(to: notes, atomically: true, encoding: .utf8)
            var saved: [URL] = []
            rig.model.replyLinks.savePathFile = { file, _, _ in saved.append(file) }
            let view = try Self.view(rig)
            let items = try #require(view.pathMenuItems(notes.path), "\(wireOnly): a local chat's file has its menu")
            let save = try #require(items.first { $0.title == AgentPaneMenuStrings.saveAs })
            let connection = try await Self.turnRemote(rig, wireOnly: wireOnly)
            Self.run(save)
            #expect(saved.isEmpty, "\(wireOnly): saved \(saved)")
            if let connection { rig.model.transport.close(connection: connection) }
        }
    }

    /// The control: the same row in a chat that stays on this Mac saves the file.
    @Test func aLocalChatsPathMenuStillActs() async throws {
        let rig = try Self.rig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        let notes = rig.project.appendingPathComponent("notes.md")
        try "hi\n".write(to: notes, atomically: true, encoding: .utf8)
        var saved: [URL] = []
        rig.model.replyLinks.savePathFile = { file, _, _ in saved.append(file) }
        let items = try #require(try Self.view(rig).pathMenuItems(notes.path))
        Self.run(try #require(items.first { $0.title == AgentPaneMenuStrings.saveAs }))
        #expect(saved.map { $0.resolvingSymlinksInPath().path } == [notes.resolvingSymlinksInPath().path])
    }

    /// The connection a test opened, for its cleanup.
    @MainActor private final class Opened {
        var connection: Int?
    }

    private static func turnRemote(_ model: AgentPaneModel, wireOnly: Bool, into opened: Opened) async {
        opened.connection = try? await turnRemote(model, wireOnly: wireOnly)
    }

    /// An image's read runs off the main actor; a chat that turns remote while it runs gets no
    /// bytes of this Mac's file, and a chat that stays local still gets its image.
    @Test func anImageReadThatOutlivesTheChatTurningRemoteSendsNothing() async throws {
        let picture = "data:image/png;base64,iVBORw0KGgo="
        for wireOnly in [false, true] {
            let rig = try Self.rig()
            defer { try? FileManager.default.removeItem(at: rig.folder) }
            let shot = rig.project.appendingPathComponent("shot.png")
            try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: shot)
            rig.model.replyLinks.readLocalImage = { _ in .success(picture) }
            let local = await Self.ask(rig.model, "image.load", ["src": shot.path])
            #expect((local["value"] as? [String: Any])?["src"] as? String == picture, "\(wireOnly): \(local)")

            let model = rig.model
            let opened = Opened()
            rig.model.replyLinks.readLocalImage = { _ in
                await Self.turnRemote(model, wireOnly: wireOnly, into: opened)
                return .success(picture)
            }
            let reply = await Self.ask(rig.model, "image.load", ["src": shot.path])
            #expect(Self.errorCode(reply) == AgentPaneReplyError.pathOutsideRoots.rawValue, "\(wireOnly): \(reply)")
            #expect((reply["value"] as? [String: Any])?["src"] == nil, "\(wireOnly): \(reply)")
            if let connection = opened.connection { rig.model.transport.close(connection: connection) }
        }
    }

    /// Copy reads the file after the row is picked; a chat that turns remote before the read ends
    /// puts nothing on the pasteboard.
    @Test func aCopyWhoseReadOutlivesTheChatTurningRemoteCopiesNothing() async throws {
        let rig = try Self.rig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        let notes = rig.project.appendingPathComponent("notes.md")
        try "hi\n".write(to: notes, atomically: true, encoding: .utf8)
        var copied = 0
        #expect(await AgentPaneFileRows(copyItem: { _ in copied += 1; return true }).copy(notes))
        #expect(copied == 1)
        // Local when the row runs, remote once the read is done.
        var checks = 0
        let rows = AgentPaneFileRows(copyItem: { _ in copied += 1; return true }, allowed: {
            checks += 1
            return checks == 1
        })
        #expect(await rows.copy(notes) == false)
        #expect(copied == 1)
    }

    /// Save As… copies the file when the save panel answers; the menu hands it a live check, so
    /// a chat that turns remote while the panel is up saves nothing.
    @Test func aSavePanelThatOutlivesTheChatTurningRemoteSavesNothing() async throws {
        for wireOnly in [false, true] {
            let rig = try Self.rig()
            defer { try? FileManager.default.removeItem(at: rig.folder) }
            let notes = rig.project.appendingPathComponent("notes.md")
            try "hi\n".write(to: notes, atomically: true, encoding: .utf8)
            var checks: [@MainActor () -> Bool] = []
            rig.model.replyLinks.savePathFile = { _, _, allowed in checks.append(allowed) }
            let items = try #require(try Self.view(rig).pathMenuItems(notes.path))
            Self.run(try #require(items.first { $0.title == AgentPaneMenuStrings.saveAs }))
            let allowed = try #require(checks.first, "\(wireOnly): Save As asked for no panel")
            #expect(allowed(), "\(wireOnly): a local chat's panel saves")
            let connection = try await Self.turnRemote(rig, wireOnly: wireOnly)
            #expect(!allowed(), "\(wireOnly): the panel's answer would save this Mac's file")
            if let connection { rig.model.transport.close(connection: connection) }
        }
    }

    /// Open With ▸ Other… opens the file when the app panel answers: nothing opens once the
    /// menu's check says the chat has turned remote.
    @Test func anOpenWithPanelThatOutlivesTheChatTurningRemoteOpensNothing() {
        let router = LinkRouter()
        var menu = LinkMenu(router: router)
        var local = true
        menu.allowed = { local }
        local = false
        menu.openChosen(URL(fileURLWithPath: "/System/Applications/TextEdit.app"), for: URL(fileURLWithPath: "/tmp/notes.md"))
        #if DEBUG
        #expect(router.recorded.isEmpty)
        #endif
    }
    /// A dragged SVG goes out as its rebuilt copy, written off the main actor; a chat that turns
    /// remote while the rebuild runs drags nothing, and a chat that stays local drags the copy.
    @Test func anSVGDragThatOutlivesTheChatTurningRemoteDragsNothing() async throws {
        for wireOnly in [false, true] {
            let rig = try Self.rig()
            defer { try? FileManager.default.removeItem(at: rig.folder) }
            let drawing = rig.project.appendingPathComponent("drawing.svg")
            try #"<svg xmlns="http://www.w3.org/2000/svg" width="4" height="4"/>"#.write(to: drawing, atomically: true, encoding: .utf8)
            var dragged: [URL] = []
            rig.model.replyLinks.mouseHeld = { true }
            rig.model.replyLinks.startDrag = { dragged.append($0); return true }
            rig.model.replyLinks.imageFolder = rig.folder.appendingPathComponent("copies", isDirectory: true)
            rig.model.replyLinks.rebuildCopy = { _, _ in true }
            let local = await Self.ask(rig.model, "file.drag", ["path": drawing.path])
            #expect(Self.errorCode(local) == nil, "\(wireOnly): \(local)")
            #expect(dragged.count == 1, "\(wireOnly): a local chat's SVG drags its copy")

            let model = rig.model
            let opened = Opened()
            rig.model.replyLinks.rebuildCopy = { _, _ in
                await Self.turnRemote(model, wireOnly: wireOnly, into: opened)
                return true
            }
            let reply = await Self.ask(rig.model, "file.drag", ["path": drawing.path])
            #expect(Self.errorCode(reply) != nil, "\(wireOnly): \(reply)")
            #expect(dragged.count == 1, "\(wireOnly): dragged \(dragged)")
            if let connection = opened.connection { rig.model.transport.close(connection: connection) }
        }
    }

    /// The paths a stand-in remote image loader was asked for.
    private actor Loads {
        var paths: [String] = []
        func add(_ path: String) { paths.append(path) }
    }

    private static func png() throws -> Data {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    /// A chat the model has marked remote keeps its raster image: `link.inspect` gives it a place
    /// without a lookup here, and `image.load` reads it on its own machine. A chat whose wire alone
    /// is remote gets neither, and never reaches the loader.
    @Test func aRemoteChatsImageLoadsFromItsOwnMachine() async throws {
        let picture = try Self.png()
        for wireOnly in [false, true] {
            let rig = try Self.rig()
            defer { try? FileManager.default.removeItem(at: rig.folder) }
            let opened = Opened()
            if wireOnly {
                await Self.turnRemote(rig.model, wireOnly: true, into: opened)
            } else {
                rig.model.remoteChat = true
            }
            // The reply dispatcher hands `image.load` the transport's loader (the wire's), so the
            // stand-in goes there, after the wire (if any) set its own.
            let loads = Loads()
            rig.model.transport.remoteImageLoader = { path in
                await loads.add(path)
                return picture
            }
            let shot = "/remote/out/shot.png"
            let inspect = await Self.ask(rig.model, "link.inspect", ["paths": [shot], "urls": [String]()])
            let places = try #require((inspect["value"] as? [String: Any])?["paths"] as? [String: Any], "\(inspect)")
            let reply = await Self.ask(rig.model, "image.load", ["src": shot])
            if wireOnly {
                #expect(places.isEmpty, "\(inspect)")
                #expect(Self.errorCode(reply) == AgentPaneReplyError.pathOutsideRoots.rawValue, "\(reply)")
                #expect(await loads.paths.isEmpty)
            } else {
                #expect((places[shot] as? [String: Any])?["place"] as? String == "root", "\(inspect)")
                let src = try #require((reply["value"] as? [String: Any])?["src"] as? String, "\(reply)")
                #expect(src.hasPrefix("data:image/png;base64,"))
                #expect(await loads.paths == [shot])
            }
            #expect(rig.lookups.count == 0, "\(wireOnly): the host looked up a remote chat's path here")
            if let connection = opened.connection { rig.model.transport.close(connection: connection) }
        }
    }
}
