import AppKit
@testable import CmuxNextAgentPane
import Foundation
import Testing

/// The user, 2026-10-21: "in chief i need to be able to right click any image/video etc 'copy'".
/// A right-click on an image in an agent chat (Chromium or WebKit page) offers Open Image, Copy
/// Image, Save Image As…, Quick Look and Show in Finder. The page sends the image it shows (a
/// `data:` URL) and the host keeps a named copy: Copy puts that file and the image's bytes on the
/// pasteboard, Save As… offers it under the image's own name, Quick Look previews it. Each spends
/// the person's click.
@MainActor @Suite(.serialized)
struct AgentPaneImageMenuActionsTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// A real 2×2 PNG.
    private static let png: Data = {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }()
    private static let pngSource = "data:image/png;base64," + png.base64EncodedString()

    private static func ask(_ model: AgentPaneModel, _ method: String, _ params: [String: Any], click: Bool = true) async -> [String: Any] {
        if click { model.transport.gestures.record(click: true) }
        return await model.respond(to: AgentPaneRequest(body: ["method": method, "params": params]))
    }

    private static func errorCode(_ reply: [String: Any]) -> String? {
        (reply["error"] as? [String: Any])?["code"] as? String
    }

    private static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("image-menu-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private final class Effects {
        var saved: [(URL, String)] = []
        var looked: [URL] = []
    }

    private static func model(_ folder: URL, pasteboard: NSPasteboard) -> (AgentPaneModel, Effects) {
        let model = AgentPaneModel(host: NoHost())
        let effects = Effects()
        model.replyLinks.imageFolder = folder.appendingPathComponent("copies", isDirectory: true)
        model.replyLinks.pasteboard = pasteboard
        model.replyLinks.saveFile = { effects.saved.append(($0, $1)) }
        model.replyLinks.quickLookFile = { effects.looked.append($0) }
        return (model, effects)
    }

    @Test func copyImagePutsTheFileAndItsBytesOnThePasteboard() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let board = NSPasteboard(name: .init("image-menu-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let (model, _) = Self.model(folder, pasteboard: board)

        let reply = await Self.ask(model, "image.copy", ["src": Self.pngSource, "name": "chart.png"])
        #expect(Self.errorCode(reply) == nil, "\(reply)")
        let files = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let file = try #require(files.first)
        #expect(file.pathExtension == "png")
        #expect(try Data(contentsOf: file) == Self.png)
        #expect(board.data(forType: .png) == Self.png)
        #expect(NSImage(pasteboard: board) != nil)

        // No click, no copy.
        board.clearContents()
        let unclicked = await Self.ask(model, "image.copy", ["src": Self.pngSource, "name": "chart.png"], click: false)
        #expect(Self.errorCode(unclicked) == AgentPaneReplyError.gestureRequired.rawValue)
        #expect(board.data(forType: .png) == nil)
    }

    @Test func saveImageAsOffersTheCopyUnderTheImagesOwnName() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (model, effects) = Self.model(folder, pasteboard: NSPasteboard(name: .init("image-menu-\(UUID().uuidString)")))

        let reply = await Self.ask(model, "image.save", ["src": Self.pngSource, "name": "build log"])
        #expect(Self.errorCode(reply) == nil, "\(reply)")
        let (file, name) = try #require(effects.saved.first)
        #expect(try Data(contentsOf: file) == Self.png)
        #expect(name == "build log.png")
    }

    @Test func quickLookPreviewsTheCopy() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (model, effects) = Self.model(folder, pasteboard: NSPasteboard(name: .init("image-menu-\(UUID().uuidString)")))

        let reply = await Self.ask(model, "image.quickLook", ["src": Self.pngSource, "name": "chart"])
        #expect(Self.errorCode(reply) == nil, "\(reply)")
        let file = try #require(effects.looked.first)
        #expect(try Data(contentsOf: file) == Self.png)

        let text = await Self.ask(model, "image.quickLook", ["src": "data:text/html;base64,PGgxPg==", "name": "x"])
        #expect(Self.errorCode(text) != nil)
        #expect(effects.looked.count == 1)
    }

    @Test func theImageMenuOffersCopySaveQuickLookAndShowInFinder() {
        var ran: [String] = []
        let menu = NSMenu()
        AgentPaneContextMenu.rebuild(menu, target: AgentPaneMessageTarget(text: "", opensImage: true), devTools: false,
                                     actions: .init(copy: { _ in }, fork: { _ in }, page: { name, _ in ran.append(name) }))
        let titles = menu.items.map(\.title)
        #expect(Array(titles.prefix(5)) == [AgentPaneMenuStrings.openImage, AgentPaneMenuStrings.copyImage,
                                            AgentPaneMenuStrings.saveImageAs, AgentPaneMenuStrings.quickLook,
                                            AgentPaneMenuStrings.showInFinder])
        for item in menu.items.prefix(5) {
            _ = (item.target as? NSObject)?.perform(item.action, with: item)
        }
        #expect(ran == ["chat.menu.openImage", "chat.menu.copyImage", "chat.menu.saveImage", "chat.menu.quickLookImage",
                        "chat.menu.revealImage"])
    }
}
