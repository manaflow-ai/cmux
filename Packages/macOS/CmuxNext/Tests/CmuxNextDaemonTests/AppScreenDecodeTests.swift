import Foundation
import Synchronization
import Testing
@testable import CmuxNextDaemon

/// The app screen read shape (`app-screens-v1`, plans/cmux-next/app-screens.md 2):
/// `screens[].kind` and `app`, and the flat `app` tab. Everything absent
/// reads as today's ordinary screen.
@Suite(.timeLimit(.minutes(1))) struct AppScreenDecodeTests {
    private func screen(_ json: String) throws -> ScreenSnapshot {
        try JSONDecoder().decode(ScreenSnapshot.self, from: Data(json.utf8))
    }

    private func tab(_ json: String) throws -> TabSnapshot {
        try JSONDecoder().decode(TabSnapshot.self, from: Data(json.utf8))
    }

    @Test func anAppScreenKeepsItsKindAndApp() throws {
        let s = try screen(#"{"id":1,"layout":{"type":"leaf","pane":2},"kind":"app","app":"app-store"}"#)
        #expect(s.kind == .app)
        #expect(s.app == "app-store")
    }

    /// v1 has only `app` screens (R90): an `appColumn` screen from any
    /// daemon reads as an ordinary screen, its columns as ordinary columns.
    @Test func anAppColumnKindReadsAsWorkspace() throws {
        let s = try screen(#"""
        {"id":1,"layout":{"type":"leaf","pane":2},"kind":"appColumn","app":"home","columns":[
          {"id":5,"width":0.3,"layout":{"type":"leaf","pane":2},"sticky":{"edge":"left","mode":"docked"},"app":"home"},
          {"id":6,"width":0.7,"layout":{"type":"leaf","pane":3}}]}
        """#)
        #expect(s.kind == .workspace)
        #expect(s.app == nil)
    }

    @Test func anOlderDaemonSendsOrdinaryScreens() throws {
        let s = try screen(#"{"id":1,"layout":{"type":"leaf","pane":2},"columns":[{"id":5,"width":1,"layout":{"type":"leaf","pane":2}}]}"#)
        #expect(s.kind == .workspace)
        #expect(s.app == nil)
    }

    /// A newer kind, or an app kind without its app, is shown as an ordinary
    /// screen rather than dropped.
    @Test func anUnknownKindOrAMissingAppReadsAsWorkspace() throws {
        #expect(try screen(#"{"id":1,"layout":{"type":"leaf","pane":2},"kind":"dashboard","app":"x"}"#).kind == .workspace)
        #expect(try screen(#"{"id":1,"layout":{"type":"leaf","pane":2},"kind":"app"}"#).kind == .workspace)
        #expect(try screen(#"{"id":1,"layout":{"type":"leaf","pane":2},"kind":"app","app":""}"#).kind == .workspace)
        #expect(try screen(#"{"id":1,"layout":{"type":"leaf","pane":2},"kind":"workspace","app":"x"}"#).app == nil)
    }

    @Test func anAppTabIsFlatAndFrontendOwned() throws {
        let t = try tab(#"{"surface":7,"kind":"app","app":"coderouter","route":"/accounts","title":"CodeRouter"}"#)
        #expect(t.kind == .app)
        #expect(t.app == "coderouter")
        #expect(t.route == "/accounts")
        #expect(t.isFrontendOwned)
        let bare = try tab(#"{"surface":7,"kind":"app","app":"home"}"#)
        #expect(bare.route == nil)
        #expect(TabKind(rawValue: "app").rawValue == "app")
    }

    @Test func appFieldsOnAnotherKindAreIgnored() throws {
        let t = try tab(#"{"surface":7,"kind":"pty","app":"home","route":"/"}"#)
        #expect(t.app == nil)
        #expect(t.route == nil)
    }

    @Test func theScreenModelFollowsKindChanges() async throws {
        await MainActor.run {
            let model = ScreenModel(ScreenSnapshot(id: 1, layout: .leaf(2)))
            #expect(model.kind == .workspace)
            model.update(ScreenSnapshot(id: 1, layout: .leaf(2), kind: .app, app: "app-store"))
            #expect(model.kind == .app)
            #expect(model.app == "app-store")
        }
    }

    @Test func appScreensIsAnAdvertisedCapability() {
        #expect(DaemonCapabilities.shared.appScreens == "app-screens-v1")
        #expect(DaemonCapabilities.shared.advertised.contains("app-screens-v1"))
    }

    /// `workspace.ensure_app {app, kind}` sends both params with an
    /// idempotency key and returns the workspace and screen ids.
    @Test func ensureAppSendsAppAndKindAndReturnsTheWorkspace() async throws {
        let seen = Mutex<[String: JSONValue]>([:])
        let server = try FakeDaemonServer(handler: ConnectionTests.handshake { request, _ in
            guard request["protocol"]?.stringValue == "cmux.protocol/2" else { return [] }
            let id = request["id"]?.stringValue ?? ""
            seen.withLock { $0 = request }
            return [#"{"protocol":"cmux.protocol/2","type":"response","id":"\#(id)","ok":true,"result":{"value":{"workspace_id":"workspace_9","screen_id":"screen_4"},"revision":"3","replayed":false}}"#]
        })
        defer { server.stop() }
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: server.path))
        try await connection.start()
        let ensured = try await AppWorkspaceClient(connection).ensureApp("cmux/home", displayName: "Home")
        #expect(ensured.workspaceID == ResourceID(rawValue: "workspace_9"))
        #expect(ensured.screenID == ResourceID(rawValue: "screen_4"))
        let request = seen.withLock { $0 }
        #expect(request["operation"]?.stringValue == "workspace.ensure_app")
        #expect(request["params"]?["app"]?.stringValue == "cmux/home")
        #expect(request["params"]?["display_name"]?.stringValue == "Home")
        #expect(request["params"]?["kind"]?.stringValue == "app")
        #expect(request["idempotency_key"]?.stringValue?.isEmpty == false)
        await connection.close()
    }
}
