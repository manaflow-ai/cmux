import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A native drop's paths go to the page with the drop itself (`cmux-files-dropped`), and a chat on
/// another machine has each pushed file put there from its path (`chat.upload.begin` naming the
/// push's token). Leo, 2026-11-18: "you can just send it instantly. Like, stop blocking."
@MainActor
struct AgentPaneDroppedPushTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// The chat's staged upload, as each request reached it; it keeps the bytes it was sent.
    private final class Stage {
        var requests: [String] = []
        var bytes = Data()
    }

    private static func items(_ payload: [String: Any]?) -> [[String: Any]] {
        payload?["items"] as? [[String: Any]] ?? []
    }

    @Test func aLocalDropIsPushedAsPathsAndLinked() throws {
        let paths = AgentPaneDroppedPaths()
        paths.stash([URL(fileURLWithPath: "/Users/you/Desktop/clip.mov"), URL(fileURLWithPath: "/Users/you/docs/", isDirectory: true)], kind: .drop)
        let payload = try #require(paths.pushed(local: true))
        #expect(payload["local"] as? Bool == true)
        let items = Self.items(payload)
        #expect(items.map { $0["path"] as? String } == ["/Users/you/Desktop/clip.mov", "/Users/you/docs"])
        #expect(items.map { $0["folder"] as? Bool } == [false, true])
        #expect(items.allSatisfy { $0["token"] == nil })
        #expect(paths.linkedFiles == ["/Users/you/Desktop/clip.mov", "/Users/you/docs"])
        let script = try #require(AgentPaneDroppedPaths.pushScript(payload))
        #expect(script.hasPrefix("window.dispatchEvent(new CustomEvent('cmux-files-dropped', {detail: {"))
    }

    /// A drop goes as this Mac's paths only once the page has its handshake and its chat is on this
    /// Mac: before the handshake a page on a remote route still reads `remoteChat == false`.
    @Test func dropsGoAsLocalPathsOnlyAfterTheHandshakeOnThisMac() {
        let model = AgentPaneModel(host: NoHost())
        model.onLocalPaths = { true }
        #expect(!model.dropsGoAsLocalPaths)
        model.hasHandshake = true
        #expect(model.dropsGoAsLocalPaths)
        model.remoteChat = true
        #expect(!model.dropsGoAsLocalPaths)
        model.remoteChat = false
        model.onLocalPaths = { false }
        #expect(!model.dropsGoAsLocalPaths)
    }

    @Test func noDropPushesNothing() {
        #expect(AgentPaneDroppedPaths().pushed(local: true) == nil)
    }

    @Test func aRemoteDropsTokenNamesItsFileOnce() throws {
        let paths = AgentPaneDroppedPaths()
        paths.stash([URL(fileURLWithPath: "/Users/you/clip.mov")], kind: .drop)
        let item = try #require(Self.items(paths.pushed(local: false)).first)
        let token = try #require(item["token"] as? String)
        #expect(AgentPaneDroppedPaths.isPutToken(token))
        #expect(paths.linkedFiles.isEmpty)
        // Another file's name never takes it, and uses it up.
        #expect(paths.takePut(token, name: "other.mov") == nil)
        #expect(paths.takePut(token, name: "clip.mov") == nil)
        paths.stash([URL(fileURLWithPath: "/Users/you/clip.mov")], kind: .drop)
        let again = try #require(Self.items(paths.pushed(local: false)).first?["token"] as? String)
        #expect(paths.takePut(again, name: "clip.mov")?.path == "/Users/you/clip.mov")
        #expect(paths.takePut(again, name: "clip.mov") == nil)
    }

    @Test func aBeginNamingAPushedTokenStagesTheFileFromItsPath() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pushed-\(UUID().uuidString).bin")
        let bytes = Data((0..<(1_200 * 1024)).map { UInt8($0 % 251) })
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let model = AgentPaneModel(host: NoHost())
        model.adoptSession("peer-chat")
        let stage = Stage()
        model.onUploadStage = {
            { request, session in
                switch request {
                case .begin(let name, let size, _, _):
                    stage.requests.append("begin \(name) \(size) \(session ?? "-")")
                    return AgentPaneReply.success(["token": "s1", "size": size, "chunkSize": 512 * 1024])
                case .chunk(_, let offset, let data):
                    stage.requests.append("chunk \(offset)")
                    stage.bytes.append(data.bytes() ?? Data())
                    return AgentPaneReply.success(["offset": offset + data.count])
                case .finish:
                    stage.requests.append("finish")
                    return AgentPaneReply.success(["path": "/srv/uploads/\(file.lastPathComponent)"])
                case .cancel:
                    stage.requests.append("cancel")
                    return AgentPaneReply.success()
                }
            }
        }
        model.droppedPaths.stash([file], kind: .drop)
        let token = try #require(Self.items(model.droppedPaths.pushed(local: false)).first?["token"] as? String)
        let reply = await model.respond(to: AgentPaneRequest(body: [
            "method": "chat.upload.begin", "params": ["name": file.lastPathComponent, "size": bytes.count, "batchToken": token],
        ]))
        #expect((reply["value"] as? [String: Any])?["path"] as? String == "/srv/uploads/\(file.lastPathComponent)")
        #expect(stage.requests == ["begin \(file.lastPathComponent) \(bytes.count) peer-chat", "chunk 0", "chunk 524288", "chunk 1048576", "finish"])
        #expect(stage.bytes == bytes)
    }

    @Test func aBeginWithNoStageIsUnsupportedSoThePageSendsTheBytes() async throws {
        let model = AgentPaneModel(host: NoHost())
        model.droppedPaths.stash([URL(fileURLWithPath: "/Users/you/clip.mov")], kind: .drop)
        let token = try #require(Self.items(model.droppedPaths.pushed(local: false)).first?["token"] as? String)
        let reply = await model.respond(to: AgentPaneRequest(body: [
            "method": "chat.upload.begin", "params": ["name": "clip.mov", "size": 10, "batchToken": token],
        ]))
        #expect((reply["error"] as? [String: Any])?["code"] as? String == "unsupported")
    }
}
