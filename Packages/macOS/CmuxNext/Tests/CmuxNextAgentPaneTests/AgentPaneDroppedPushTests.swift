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

    /// The App's puts, as `[path, session]`.
    private final class Puts {
        var calls: [[String]] = []
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

    @Test func aBeginNamingAPushedTokenPutsTheFileFromItsPath() async throws {
        let model = AgentPaneModel(host: NoHost())
        model.adoptSession("peer-chat")
        let put = Puts()
        model.onPathPut = {
            { file, session in
                put.calls.append([file.path, session])
                return .path("/srv/uploads/clip.mov")
            }
        }
        model.droppedPaths.stash([URL(fileURLWithPath: "/Users/you/clip.mov")], kind: .drop)
        let token = try #require(Self.items(model.droppedPaths.pushed(local: false)).first?["token"] as? String)
        let reply = await model.respond(to: AgentPaneRequest(body: [
            "method": "chat.upload.begin", "params": ["name": "clip.mov", "size": 200 * 1024 * 1024, "batchToken": token],
        ]))
        #expect((reply["value"] as? [String: Any])?["path"] as? String == "/srv/uploads/clip.mov")
        #expect(put.calls == [["/Users/you/clip.mov", "peer-chat"]])
    }

    @Test func aBeginWithNoAppPutIsUnsupportedSoThePageSendsTheBytes() async throws {
        let model = AgentPaneModel(host: NoHost())
        model.adoptSession("peer-chat")
        model.droppedPaths.stash([URL(fileURLWithPath: "/Users/you/clip.mov")], kind: .drop)
        let token = try #require(Self.items(model.droppedPaths.pushed(local: false)).first?["token"] as? String)
        let reply = await model.respond(to: AgentPaneRequest(body: [
            "method": "chat.upload.begin", "params": ["name": "clip.mov", "size": 10, "batchToken": token],
        ]))
        #expect((reply["error"] as? [String: Any])?["code"] as? String == "unsupported")
    }
}
