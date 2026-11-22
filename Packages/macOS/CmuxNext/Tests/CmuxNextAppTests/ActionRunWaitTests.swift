import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextSettings
import Foundation
import Synchronization
import Testing

/// `action.run` with `wait` answers after every daemon command the action
/// sent has replied, whatever path the handler used to send it: a bare
/// `Task` around `DaemonService.run` or `perform` is awaited like `send`,
/// and a daemon rejection fails the run instead of `ran: true`.
@MainActor @Suite(.timeLimit(.minutes(1))) struct ActionRunWaitTests {
    nonisolated static let key = "0b6c4a52-6d3f-4c55-9d53-8f1f4e0f1a11"

    /// A daemon that rejects `rename-workspace` and answers everything else.
    nonisolated final class Counter: Sendable {
        let value = Mutex(0)
        let mutationIDs = Mutex<[String]>([])
    }

    nonisolated static func daemon(renames: Counter) -> @Sendable ([String: CmuxNextDaemon.JSONValue]) -> [String] {
        { request in
            let id = request["id"]?.doubleValue.map { Int($0) } ?? 0
            switch request["cmd"]?.stringValue {
            case "identify":
                let caps = DaemonCapabilities.shared.required.map { "\"\($0)\"" }.joined(separator: ",")
                return [#"{"id":\#(id),"ok":true,"data":{"app":"cmux-tui","version":"0.1.0","build_commit":"3412812eae76","protocol":12,"capabilities":[\#(caps)],"session":"local","pid":7,"registry_id":"r","generation":"g1","workspace_revision":0}}"#]
            case "list-workspaces":
                return [#"{"id":\#(id),"ok":true,"data":{"generation":"g1","registry_id":"r","workspace_revision":0,"workspaces":[]}}"#]
            case "rename-workspace":
                renames.value.withLock { $0 += 1 }
                if let mutation = request["mutation_id"]?.stringValue { renames.mutationIDs.withLock { $0.append(mutation) } }
                return [#"{"id":\#(id),"ok":false,"error":"no such workspace"}"#]
            default:
                return [#"{"id":\#(id),"ok":true,"data":{}}"#]
            }
        }
    }

    /// Waits up to 10 s; a timeout records an Issue at the caller (``waitForCondition``).
    func waitUntil(_ what: String? = nil, sourceLocation: SourceLocation = #_sourceLocation,
                   _ condition: () -> Bool) async throws {
        try await waitForCondition(what, timeout: .seconds(10), sourceLocation: sourceLocation, condition)
    }

    @Test func aDaemonRejectionFromAnUntrackedHandlerTaskFailsTheRun() async throws {
        let renames = Counter()
        let server = try ScriptedDaemonSocket(handler: Self.daemon(renames: renames))
        defer { server.stop() }
        let service = DaemonService()
        let path = server.path
        service.start(makeConnection: { DaemonConnection(endpoint: DaemonEndpoint(socketPath: path)) })
        defer { service.shutdownConnection() }
        try await waitUntil { service.connection != nil }

        let registry = ActionRegistry()
        registry.register(Action(id: "test.untrackedRename", title: "Rename") {
            // A handler that starts its daemon command in a plain Task, as
            // the rename prompt does, without `registry.track`.
            Task {
                await service.run("rename-workspace") { connection in
                    try await connection.renameWorkspace(WorkspaceKey(rawValue: Self.key), to: "x")
                }
            }
        })
        let bridge = RegistryControlBridge(registry: registry)
        let router = ControlRouter(identity: ControlIdentity(version: "1", build: "1", bundleID: nil, tag: "test", processID: 1),
                                   executor: bridge)
        bridge.attach(to: router)
        let result = await router.handle(ControlRequest(id: "1", method: "action.run", params: [
            "action": "test.untrackedRename", "wait": true,
        ]))
        #expect(renames.value.withLock { $0 } == 1)
        guard case .failure(let error) = result else {
            Issue.record("a rejected rename reported success: \(result)")
            return
        }
        #expect(error.code == "daemon_error")
    }

    @Test func aRetryWithTheSameKeySendsTheSameMutationID() async throws {
        let renames = Counter()
        let server = try ScriptedDaemonSocket(handler: Self.daemon(renames: renames))
        defer { server.stop() }
        let service = DaemonService()
        let path = server.path
        service.start(makeConnection: { DaemonConnection(endpoint: DaemonEndpoint(socketPath: path)) })
        defer { service.shutdownConnection() }
        try await waitUntil { service.connection != nil }
        let registry = ActionRegistry()
        registry.register(Action(id: "test.rename", title: "Rename") {
            service.send("rename-workspace") { try await $0.renameWorkspace(WorkspaceKey(rawValue: Self.key), to: "x") }
        })
        // Two app runs (a fresh router each, as after a relaunch) with one key.
        for _ in 0..<2 {
            let bridge = RegistryControlBridge(registry: registry)
            let router = ControlRouter(identity: ControlIdentity(version: "1", build: "1", bundleID: nil, tag: "test", processID: 1),
                                       executor: bridge)
            bridge.attach(to: router)
            _ = await router.handle(ControlRequest(id: "1", method: "action.run", params: ["action": "test.rename", "idempotency_key": "retry-1"]))
            bridge.detach()
        }
        let ids = renames.mutationIDs.withLock { $0 }
        #expect(ids.count == 2)
        #expect(ids.first == ids.last)
    }
}
