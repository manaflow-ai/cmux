@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextDaemon
import Foundation
import Testing

/// A browser tab that an action opens goes through a command funnel, so the
/// action's scope gets a ticket and a write barrier. Without the barrier,
/// `action.run` answers from a snapshot that does not show the tab yet and
/// reports `created: []` (the `cmux browser open` regression of 772c55184089).
@MainActor @Suite(.timeLimit(.minutes(1))) struct BrowserTabCreateScopeTests {
    nonisolated static func daemon(refuse: Bool) -> @Sendable ([String: CmuxNextDaemon.JSONValue]) -> [String] {
        { request in
            let id = request["id"]?.doubleValue.map { Int($0) } ?? 0
            switch request["cmd"]?.stringValue {
            case "identify":
                let caps = (DaemonCapabilities.shared.required + [DaemonCapabilities.shared.frontendBrowserTabs])
                    .map { "\"\($0)\"" }.joined(separator: ",")
                return [#"{"id":\#(id),"ok":true,"data":{"app":"cmux-tui","version":"0.1.0","build_commit":"3412812eae76","protocol":12,"capabilities":[\#(caps)],"session":"local","pid":7,"registry_id":"r","generation":"g1","workspace_revision":0}}"#]
            case "list-workspaces":
                return [#"{"id":\#(id),"ok":true,"data":{"generation":"g1","registry_id":"r","workspace_revision":0,"workspaces":[]}}"#]
            case "new-frontend-browser-tab":
                if refuse { return [#"{"id":\#(id),"ok":false,"error":"no such pane"}"#] }
                return [#"{"id":\#(id),"ok":true,"data":{"surface":10}}"#]
            default:
                return [#"{"id":\#(id),"ok":true,"data":{}}"#]
            }
        }
    }

    func connected(refuse: Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws
        -> (ScriptedDaemonSocket, DaemonService, BrowserTabService) {
        let server = try ScriptedDaemonSocket(handler: Self.daemon(refuse: refuse))
        let service = DaemonService()
        let path = server.path
        service.start(makeConnection: { DaemonConnection(endpoint: DaemonEndpoint(socketPath: path)) })
        try await waitForCondition(timeout: .seconds(10), sourceLocation: sourceLocation) { service.connection != nil }
        return (server, service, BrowserTabService(daemon: service, cef: CEFEngine(layout: nil)))
    }

    @Test func aCreatedTabNotesABarrierInTheActionScope() async throws {
        let (server, service, tabs) = try await connected(refuse: false)
        defer { server.stop(); service.shutdownConnection() }
        let scope = DaemonCommandScope()
        let surface = try await DaemonCommandScope.$current.withValue(scope) {
            try await tabs.create(PaneID(rawValue: 3), "https://example.com/", .webkit, nil, true, nil)
        }
        #expect(surface == SurfaceID(rawValue: 10))
        #expect(scope.created == [DaemonCreatedObject(.tab, SurfaceID(rawValue: 10).description)])
        #expect(scope.ticketCount == 1, "the create opens a ticket")
        #expect(scope.isIdle)
        #expect(scope.barrier(machine: DaemonCommandScope.localMachine) != nil,
                "action.run waits for this barrier before it maps created ids")
    }

    @Test func aRefusedCreateFailsTheScopeAndThrows() async throws {
        let (server, service, tabs) = try await connected(refuse: true)
        defer { server.stop(); service.shutdownConnection() }
        let scope = DaemonCommandScope()
        await #expect(throws: (any Error).self) {
            try await DaemonCommandScope.$current.withValue(scope) {
                _ = try await tabs.create(PaneID(rawValue: 3), "https://example.com/", .webkit, nil, true, nil)
            }
        }
        #expect(scope.failures.count == 1)
        #expect(scope.isIdle)
    }
}
