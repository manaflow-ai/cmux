@testable import CmuxNextAgentPane
import CmuxNextSettings
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// An image an agent names in a reply from outside the session's folders (a screenshot in
/// `/tmp`) shows inline (`image.load`): the host reads it read-only, only when it is a raster
/// image that decodes, never under `agentPane.links.outsideRoots = text`, and never from a
/// deny-listed path. Every refusal answers `link.path_outside_roots`.
@MainActor
struct AgentPaneReplyImageOutsideTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// A real 4x4 PNG, so ImageIO decodes it.
    private static func png() throws -> Data {
        let context = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        return output as Data
    }

    @MainActor private struct Rig {
        let model: AgentPaneModel
        let folder: URL
        let home: URL
        let outside: URL
        let project: URL

        func load(_ path: String) async -> [String: Any] {
            await model.respond(to: AgentPaneRequest(body: ["method": "image.load", "params": ["src": path]]))
        }
    }

    private static func rig() throws -> Rig {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("reply-image-outside-\(UUID().uuidString)", isDirectory: true)
        let home = folder.appendingPathComponent("home", isDirectory: true)
        let outside = folder.appendingPathComponent("tmp-shots", isDirectory: true)
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

    private static func source(_ reply: [String: Any]) -> String? {
        (reply["value"] as? [String: Any])?["src"] as? String
    }

    @Test func anOutsidePNGLoadsAsItsDataURLUnderOpenAndConfirm() async throws {
        let rig = try Self.rig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        let png = try Self.png()
        let shot = rig.outside.appendingPathComponent("after-messages.png")
        try png.write(to: shot)

        for outsideRoots in [AgentPaneReplySetting.OutsideRoots.open, .confirm] {
            rig.model.replyLinks.settings = { AgentPaneReplySetting(outsideRoots: outsideRoots, remoteImages: .click) }
            let reply = await rig.load(shot.path)
            #expect(Self.errorCode(reply) == nil, "\(outsideRoots): \(reply)")
            #expect(Self.source(reply) == "data:image/png;base64," + png.base64EncodedString(), "\(outsideRoots)")
        }
    }

    @Test func outsideRootsTextKeepsAnOutsideImageACard() async throws {
        let rig = try Self.rig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        let shot = rig.outside.appendingPathComponent("after-messages.png")
        try Self.png().write(to: shot)
        rig.model.replyLinks.settings = { AgentPaneReplySetting(outsideRoots: .text, remoteImages: .click) }

        let reply = await rig.load(shot.path)
        #expect(Self.errorCode(reply) == AgentPaneReplyError.pathOutsideRoots.rawValue)
        #expect(Self.source(reply) == nil)
    }

    @Test func aDenyListedImageIsNeverRead() async throws {
        let rig = try Self.rig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        let png = try Self.png()
        let secret = rig.home.appendingPathComponent(".ssh", isDirectory: true).appendingPathComponent("shot.png")
        try png.write(to: secret)
        let keyNamed = rig.outside.appendingPathComponent("server.key")
        try png.write(to: keyNamed)
        // A harmless name outside the folders that points at the secret.
        let link = rig.outside.appendingPathComponent("harmless.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)

        for path in [secret.path, keyNamed.path, link.path] {
            let reply = await rig.load(path)
            #expect(Self.errorCode(reply) == AgentPaneReplyError.pathDenied.rawValue, "\(path): \(reply)")
            #expect(Self.source(reply) == nil)
        }
    }

    @Test func anOutsideFileThatIsNotARasterImageIsRefused() async throws {
        let rig = try Self.rig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        let text = rig.outside.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: text)
        // Named as an image, but its bytes are not one.
        let fake = rig.outside.appendingPathComponent("fake.png")
        try Data("not an image".utf8).write(to: fake)
        // A raster image under a name that is not an image's: never read.
        let renamed = rig.outside.appendingPathComponent("shot.dat")
        try Self.png().write(to: renamed)
        // SVG and PDF show only from inside the folders.
        let svg = rig.outside.appendingPathComponent("chart.svg")
        try Data("<svg xmlns='http://www.w3.org/2000/svg' width='4' height='4'/>".utf8).write(to: svg)
        let missing = rig.outside.appendingPathComponent("gone.png")

        for url in [text, fake, renamed, svg, missing, rig.outside] {
            let reply = await rig.load(url.path)
            #expect(Self.errorCode(reply) == AgentPaneReplyError.pathOutsideRoots.rawValue, "\(url.lastPathComponent): \(reply)")
            #expect(Self.source(reply) == nil)
        }
    }

    @Test func anImageInsideTheFoldersStillLoads() async throws {
        let rig = try Self.rig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        let png = try Self.png()
        let shot = rig.project.appendingPathComponent("diagram.png")
        try png.write(to: shot)
        rig.model.replyLinks.settings = { AgentPaneReplySetting(outsideRoots: .text, remoteImages: .click) }

        let reply = await rig.load(shot.path)
        #expect(Self.errorCode(reply) == nil, "\(reply)")
        #expect(Self.source(reply) == "data:image/png;base64," + png.base64EncodedString())
    }

    /// A chat on another machine never reads this Mac's disk (cx-k21v): its agent can name any
    /// local path, so no local image is read for it, outside the folders or inside them.
    @Test func aRemoteChatNeverReadsThisMacsImages() async throws {
        let rig = try Self.rig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        let png = try Self.png()
        let shot = rig.outside.appendingPathComponent("after-messages.png")
        try png.write(to: shot)
        let diagram = rig.project.appendingPathComponent("diagram.png")
        try png.write(to: diagram)
        rig.model.remoteChat = true

        for outsideRoots in AgentPaneReplySetting.OutsideRoots.allCases {
            rig.model.replyLinks.settings = { AgentPaneReplySetting(outsideRoots: outsideRoots, remoteImages: .click) }
            for url in [shot, diagram] {
                let reply = await rig.load(url.path)
                #expect(Self.errorCode(reply) == AgentPaneReplyError.pathOutsideRoots.rawValue, "\(outsideRoots) \(url.lastPathComponent): \(reply)")
                #expect(Self.source(reply) == nil)
            }
        }
    }

    /// The host checks a canonical path, then opens it. A parent folder swapped for a link in
    /// between (here: a link into `~/.ssh` in place of a folder) must not reach the file it now
    /// points at: the read checks the path of the file it opened, not the path it was given.
    @Test func anOpenThroughALinkedParentFolderIsRefused() async throws {
        let rig = try Self.rig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        let png = try Self.png()
        let ssh = rig.home.appendingPathComponent(".ssh", isDirectory: true)
        try png.write(to: ssh.appendingPathComponent("shot.png"))
        let canonicalOutside = try #require(AcpmuxPathPolicy.canonical(rig.outside.path))
        let swapped = canonicalOutside + "/swapped"
        try FileManager.default.createSymbolicLink(atPath: swapped, withDestinationPath: ssh.path)

        // As the host sees it after its checks passed for `swapped/shot.png`.
        let read = await AgentPaneReplyImages.outside(swapped + "/shot.png")
        if case .success = read { Issue.record("an image behind a linked parent folder was read") }
        // Through image.load the canonical path is on the deny list.
        let reply = await rig.load(swapped + "/shot.png")
        #expect(Self.errorCode(reply) == AgentPaneReplyError.pathDenied.rawValue, "\(reply)")

        // The same image at its own canonical path, outside the deny list, still reads.
        let plain = canonicalOutside + "/plain.png"
        try png.write(to: URL(fileURLWithPath: plain))
        #expect(await AgentPaneReplyImages.outside(plain) == .success("data:image/png;base64," + png.base64EncodedString()))
    }
}
