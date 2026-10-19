import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A reply image outside the chat's folders (a screenshot the agent saved in a temporary folder)
/// follows `agentPane.links.outsideRoots` (Lucas 2026-10-17): Open loads it at once, Ask First
/// after a click in the pane, Show as Text never. A deny-listed name is refused under every one.
@Suite(.serialized)
@MainActor
struct AgentPaneReplyImageOutsideTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// A 1x1 PNG.
    private static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!

    private static func model(_ outsideRoots: AgentPaneReplySetting.OutsideRoots) -> AgentPaneModel {
        let model = AgentPaneModel(host: NoHost())
        model.replyLinks.settings = { AgentPaneReplySetting(outsideRoots: outsideRoots, remoteImages: .click) }
        return model
    }

    private static func file(_ name: String) throws -> (path: String, folder: URL) {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("reply-image-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try png.write(to: url)
        return (url.path, folder)
    }

    private static func loaded(_ reply: [String: Any]) -> Bool {
        ((reply["value"] as? [String: Any])?["src"] as? String)?.hasPrefix("data:image/png") == true
    }

    @Test func openLoadsAnOutsideImageAtOnce() async throws {
        let (path, folder) = try Self.file("shot.png")
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(Self.loaded(await Self.model(.open).loadReplyImage(path)))
    }

    @Test func askFirstLoadsAnOutsideImageOnlyAfterAClick() async throws {
        let (path, folder) = try Self.file("shot.png")
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = Self.model(.confirm)
        #expect(!Self.loaded(await model.loadReplyImage(path)))
        model.transport.gestures.record(click: true)
        #expect(Self.loaded(await model.loadReplyImage(path)))
    }

    @Test func showAsTextNeverLoadsAnOutsideImage() async throws {
        let (path, folder) = try Self.file("shot.png")
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = Self.model(.text)
        model.transport.gestures.record(click: true)
        #expect(!Self.loaded(await model.loadReplyImage(path)))
    }

    @Test func aDenyListedNameIsRefusedEvenWhenOutsideFilesOpen() async throws {
        let (path, folder) = try Self.file("id.pem")
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(!Self.loaded(await Self.model(.open).loadReplyImage(path)))
    }
}
