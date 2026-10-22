@testable import CmuxNextAgentPane
import Foundation
import Testing

/// The image viewer's Show in Finder and Open in Browser Pane (cx-ncc.39): the page sends the
/// image it shows, a `data:` URL, and the host keeps a copy named for the image with its type's
/// extension; Finder selects it, or a browser pane opens it. An image from a file inside the
/// roots of a local chat is shown as that file, else as its copy, on the same click. Each needs
/// the person's click; an SVG never opens in a pane.
@MainActor
struct AgentPaneImageActionsTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
    private static let pngSource = "data:image/png;base64," + png.base64EncodedString()

    private static func ask(_ model: AgentPaneModel, _ method: String, _ params: [String: Any], click: Bool = true) async -> [String: Any] {
        if click { model.transport.gestures.record(click: true) }
        return await model.respond(to: AgentPaneRequest(body: ["method": method, "params": params]))
    }

    private static func errorCode(_ reply: [String: Any]) -> String? {
        (reply["error"] as? [String: Any])?["code"] as? String
    }

    private static func model(_ folder: URL) -> (AgentPaneModel, revealed: () -> [URL], opened: () -> [URL]) {
        let model = AgentPaneModel(host: NoHost())
        var revealed: [URL] = []
        var opened: [URL] = []
        model.replyLinks.imageFolder = folder.appendingPathComponent("copies", isDirectory: true)
        model.replyLinks.revealFile = { revealed.append($0) }
        model.onOpenPreview = {
            opened.append($0)
            return true
        }
        return (model, { revealed }, { opened })
    }

    private static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("image-actions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func showInFinderSelectsANamedCopyOfTheImage() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (model, revealed, _) = Self.model(folder)

        let reply = await Self.ask(model, "image.reveal", ["src": Self.pngSource, "name": "build log.png"])
        #expect(Self.errorCode(reply) == nil, "\(reply)")
        let file = try #require(revealed().last)
        #expect(file.deletingLastPathComponent().lastPathComponent == "copies")
        #expect(file.lastPathComponent.hasPrefix("build log "))
        #expect(file.pathExtension == "png")
        #expect(try Data(contentsOf: file) == Self.png)

        // The same image is the same file; an image without a name is "Image", never a dot file.
        _ = await Self.ask(model, "image.reveal", ["src": Self.pngSource, "name": "build log.png"])
        // (Built, not written out: ci-target-graph.py reads a path literal as a repository read.)
        _ = await Self.ask(model, "image.reveal", ["src": Self.pngSource, "name": String(repeating: "../", count: 2)])
        try #require(revealed().count == 3)
        #expect(revealed()[1] == file)
        #expect(revealed()[2].lastPathComponent.hasPrefix("Image "))

        // A name too long for a file name, even one past the request's name cap (alt text has no
        // length limit), is cut; format characters (a right-to-left override) are dropped.
        let long = await Self.ask(model, "image.reveal", ["src": Self.pngSource, "name": String(repeating: "🖼️", count: 200)])
        #expect(Self.errorCode(long) == nil, "\(long)")
        _ = await Self.ask(model, "image.reveal", ["src": Self.pngSource, "name": "evil\u{202E}gnp.exe"])
        // A wrong count fails this test alone: an unchecked index past it would crash the test
        // process and every suite after it.
        try #require(revealed().count == 5)
        #expect(revealed()[3].lastPathComponent.utf8.count <= 255)
        #expect(FileManager.default.fileExists(atPath: revealed()[3].path))
        #expect(!revealed()[4].lastPathComponent.unicodeScalars.contains("\u{202E}"))
        #expect(revealed()[4].pathExtension == "png")

        // No click, no copy.
        let unclicked = await Self.ask(model, "image.reveal", ["src": Self.pngSource, "name": "x"], click: false)
        #expect(Self.errorCode(unclicked) == AgentPaneReplyError.gestureRequired.rawValue)
        #expect(revealed().count == 5)
    }

    @Test func openInBrowserPaneOpensTheCopyAsAFileAndNeverAnSVG() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (model, _, opened) = Self.model(folder)

        let reply = await Self.ask(model, "image.openInPane", ["src": Self.pngSource, "name": "chart"])
        #expect(Self.errorCode(reply) == nil, "\(reply)")
        let url = try #require(opened().last)
        #expect(url.isFileURL)
        #expect(url.pathExtension == "png")
        #expect(try Data(contentsOf: url) == Self.png)

        let svg = "data:image/svg+xml;base64," + Data("<svg onload='alert(1)'/>".utf8).base64EncodedString()
        let refused = await Self.ask(model, "image.openInPane", ["src": svg, "name": "chart"])
        #expect(Self.errorCode(refused) == AgentPaneReplyError.imageRefused.rawValue)
        let text = await Self.ask(model, "image.openInPane", ["src": "data:text/html;base64,PGgxPg==", "name": "x"])
        #expect(Self.errorCode(text) == AgentPaneReplyError.imageRefused.rawValue)
        let unclicked = await Self.ask(model, "image.openInPane", ["src": Self.pngSource, "name": "x"], click: false)
        #expect(Self.errorCode(unclicked) == AgentPaneReplyError.gestureRequired.rawValue)
        #expect(opened().count == 1)
    }

    @Test func anImageFromAFileInsideTheRootsIsShownAsThatFileElseAsItsCopy() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (model, revealed, _) = Self.model(folder)
        let project = folder.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let shot = project.appendingPathComponent("shot.png")
        try Self.png.write(to: shot)
        model.workspaceRoots = { [project.path] }
        let isCopy = { (url: URL) in url.deletingLastPathComponent().lastPathComponent == "copies" }

        let reply = await Self.ask(model, "image.reveal", ["src": Self.pngSource, "name": "shot.png", "path": shot.path])
        #expect(Self.errorCode(reply) == nil, "\(reply)")
        #expect(revealed().map { $0.resolvingSymlinksInPath().path } == [shot.resolvingSymlinksInPath().path])

        // A file outside the roots, a folder, a missing file, or any path in a chat on another
        // machine: the image's copy instead, on the same single click.
        let outside = folder.appendingPathComponent("elsewhere.png")
        try Self.png.write(to: outside)
        for path in [outside.path, project.path, project.appendingPathComponent("gone.png").path] {
            let fallback = await Self.ask(model, "image.reveal", ["src": Self.pngSource, "name": "x", "path": path])
            #expect(Self.errorCode(fallback) == nil, "\(path): \(fallback)")
        }
        model.remoteChat = true
        let remote = await Self.ask(model, "image.reveal", ["src": Self.pngSource, "name": "x", "path": shot.path])
        #expect(Self.errorCode(remote) == nil, "\(remote)")
        #expect(revealed().count == 5)
        #expect(revealed().dropFirst().allSatisfy(isCopy))

        // The image itself is required: a path alone is not a request.
        let pathOnly = await Self.ask(model, "image.reveal", ["src": shot.path, "name": "x"])
        #expect(Self.errorCode(pathOnly) != nil)
        #expect(revealed().count == 5)
    }
}
