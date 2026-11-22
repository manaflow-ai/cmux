@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// A split that an action runs (Cmd+D, `cmux pane split-right`, `action.run
/// splitRight`) goes through a command funnel, so the action's scope gets a
/// ticket and a write barrier. Without the barrier `action.run` with
/// `wait:true` answers from a snapshot that does not show the new pane yet
/// and reports `created: []` (measured: 8 of 12 local and 5 of 12 remote
/// runs, plans/cmux-next/remote-state-ownership.md 1.3).
@MainActor @Suite(.timeLimit(.minutes(1))) struct PaneSplitScopeTests {
    nonisolated static func daemon(refuse: Bool) -> @Sendable ([String: CmuxNextDaemon.JSONValue]) -> [String] {
        { request in
            let id = request["id"]?.doubleValue.map { Int($0) } ?? 0
            switch request["cmd"]?.stringValue {
            case "identify":
                let caps = DaemonCapabilities.shared.required.map { "\"\($0)\"" }.joined(separator: ",")
                return [#"{"id":\#(id),"ok":true,"data":{"app":"cmux-tui","version":"0.1.0","build_commit":"3412812eae76","protocol":12,"capabilities":[\#(caps)],"session":"local","pid":7,"registry_id":"r","generation":"g1","workspace_revision":0}}"#]
            case "list-workspaces":
                return [#"{"id":\#(id),"ok":true,"data":{"generation":"g1","registry_id":"r","workspace_revision":0,"workspaces":[]}}"#]
            case "split":
                if refuse { return [#"{"id":\#(id),"ok":false,"error":"pane 3 not found"}"#] }
                return [#"{"id":\#(id),"ok":true,"data":{"surface":10}}"#]
            default:
                return [#"{"id":\#(id),"ok":true,"data":{}}"#]
            }
        }
    }

    func connected(refuse: Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws
        -> (ScriptedDaemonSocket, DaemonService) {
        let server = try ScriptedDaemonSocket(handler: Self.daemon(refuse: refuse))
        let service = DaemonService()
        let path = server.path
        service.start(makeConnection: { DaemonConnection(endpoint: DaemonEndpoint(socketPath: path)) })
        try await waitForCondition(timeout: .seconds(10), sourceLocation: sourceLocation) { service.connection != nil }
        return (server, service)
    }

    func command(swap: PaneDirection? = nil) -> PaneSplitCommand {
        PaneSplitCommand(pane: PaneID(rawValue: 3), direction: .right, options: SpawnOptions(), swapTowards: swap)
    }

    @Test func aSplitNotesABarrierInTheActionScope() async throws {
        let (server, service) = try await connected(refuse: false)
        defer { server.stop(); service.shutdownConnection() }
        let scope = DaemonCommandScope()
        let created = try await DaemonCommandScope.$current.withValue(scope) {
            try await command().send(on: service)
        }
        #expect(created.surface == SurfaceID(rawValue: 10))
        #expect(scope.created.contains(DaemonCreatedObject(.tab, SurfaceID(rawValue: 10).description)))
        #expect(scope.ticketCount == 1, "the split opens a ticket")
        #expect(scope.isIdle)
        #expect(scope.barrier(machine: DaemonCommandScope.localMachine) != nil,
                "action.run waits for this barrier before it maps created ids")
    }

    @Test func aLeftSplitCoversTheSwapWithTheSameTicket() async throws {
        let (server, service) = try await connected(refuse: false)
        defer { server.stop(); service.shutdownConnection() }
        let scope = DaemonCommandScope()
        _ = try await DaemonCommandScope.$current.withValue(scope) {
            try await command(swap: .right).send(on: service)
        }
        #expect(scope.ticketCount == 1)
        #expect(scope.barrier(machine: DaemonCommandScope.localMachine) != nil)
    }

    @Test func aRefusedSplitFailsTheScopeAndThrows() async throws {
        let (server, service) = try await connected(refuse: true)
        defer { server.stop(); service.shutdownConnection() }
        let scope = DaemonCommandScope()
        await #expect(throws: (any Error).self) {
            try await DaemonCommandScope.$current.withValue(scope) {
                _ = try await command().send(on: service)
            }
        }
        #expect(scope.failures.count == 1, "action.run reports the refusal instead of a silent success")
        #expect(scope.isIdle)
    }
}
