import CmuxNextDaemon
import CmuxNextSidebar
import Foundation
import Observation
import Synchronization
import Testing
@testable import CmuxNextApp

/// A Cloud machine whose cmux-tui is too old for this app. The sidebar must
/// say so instead of "Connecting…" forever, and once the machine's daemon is
/// updated in place (its link socket stays), the app must connect without a
/// relaunch.
@MainActor @Suite(.timeLimit(.minutes(1))) struct RemoteMachineCompatTests {
    nonisolated static let required = DaemonCapabilities.shared.required

    /// identify/set-client-info/subscribe/list-workspaces for a daemon with
    /// `capabilities()`.
    nonisolated static func daemon(capabilities: @escaping @Sendable () -> [String]) -> @Sendable ([String: JSONValue]) -> [String] {
        { request in
            let id = request["id"]?.doubleValue.map { Int($0) } ?? 0
            switch request["cmd"]?.stringValue {
            case "identify":
                let caps = capabilities().map { "\"\($0)\"" }.joined(separator: ",")
                return [#"{"id":\#(id),"ok":true,"data":{"app":"cmux-tui","version":"0.1.0","build_commit":"3412812eae76","protocol":12,"capabilities":[\#(caps)],"session":"cloud","pid":7,"registry_id":"r","generation":"g1","workspace_revision":0}}"#]
            case "list-workspaces":
                return [#"{"id":\#(id),"ok":true,"data":{"generation":"g1","registry_id":"r","workspace_revision":0,"workspaces":[]}}"#]
            default:
                return [#"{"id":\#(id),"ok":true,"data":{}}"#]
            }
        }
    }

    private func waitFor(_ expected: DaemonStartupState, service: DaemonService,
                         timeout: Duration = .seconds(10)) async throws {
        let observation = Task { @MainActor () -> Bool in
            for await state in Observations({ service.startup }) where state == expected { return true }
            return false
        }
        let timeoutTask = Task<Void, Never> {
            try? await Task.sleep(for: timeout)
        }
        let observed = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await observation.value }
            group.addTask {
                await timeoutTask.value
                return false
            }
            let result = await group.next() ?? false
            observation.cancel()
            timeoutTask.cancel()
            group.cancelAll()
            return result
        }
        guard observed else {
            throw DaemonError.timedOut("daemon startup state did not become \(expected)")
        }
    }

    private func waitForConnected(_ service: DaemonService,
                                  timeout: Duration = .seconds(10)) async throws {
        let observation = Task { @MainActor () -> Bool in
            for await state in Observations({ service.store.connectionState }) {
                if case .connected = state { return true }
            }
            return false
        }
        let timeoutTask = Task<Void, Never> {
            try? await Task.sleep(for: timeout)
        }
        let observed = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await observation.value }
            group.addTask {
                await timeoutTask.value
                return false
            }
            let result = await group.next() ?? false
            observation.cancel()
            timeoutTask.cancel()
            group.cancelAll()
            return result
        }
        guard observed else {
            throw DaemonError.timedOut("daemon connection did not become connected")
        }
    }

    @Test func tooOldCloudDaemonIsNotShownAsConnectingAndConnectsOnceUpdated() async throws {
        let updated = Mutex(false)
        let server = try ScriptedDaemonSocket(handler: Self.daemon {
            updated.withLock { $0 } ? Self.required : Self.required.filter { $0 != "view-attachment-detach-v1" }
        })
        defer { server.stop() }
        let service = DaemonService(machineID: "vm-test")
        service.startupDeadline = .seconds(60)
        let path = server.path
        service.start(remote: { path })
        defer { service.shutdownConnection() }

        try await waitFor(.unavailable(.missingCapabilities(["view-attachment-detach-v1"])), service: service)
        #expect(service.startup == .unavailable(.missingCapabilities(["view-attachment-detach-v1"])))
        let header = SidebarBridge.machine(for: service, name: "vm", kind: .cloud)
        #expect(header.status != .connecting, "an incompatible machine must not look like it is still connecting")
        #expect(header.status == .updateRequired)
        // Capability ids stay in machine-readable diagnostics; the sidebar gives
        // the human update instruction without exposing an internal protocol key.
        #expect(header.detail?.localizedCaseInsensitiveContains("update") == true)
        #expect(header.detail?.contains("view-attachment-detach-v1") == false)
        #expect(service.compatibility?.level == .incompatible)

        // The machine is updated in place: same link socket, newer daemon.
        updated.withLock { $0 = true }
        service.retryWake.fire()
        try await waitForConnected(service)
        guard case .connected = service.store.connectionState else {
            Issue.record("the updated machine never connected: \(service.store.connectionState)")
            return
        }
        // Connected with the required set only: the optional features stay
        // off and the header offers the update instead of hiding it.
        #expect(service.compatibility?.level == .limited)
        // Home-only personal state does not make a remote machine limited;
        // workspace groups remain machine capabilities until the local
        // MachineRegistry has a profiles-backed home store.
        let homeOnly = Set(DaemonCapabilities.shared.homeOnly)
        #expect(service.compatibility?.missingOptional == DaemonCapabilities.shared.optional.filter { !homeOnly.contains($0) })
        #expect(SidebarBridge.machine(for: service, name: "vm", kind: .cloud).status == .updateAvailable)
        #expect(SidebarBridge.machine(for: service, name: "vm", kind: .local).status == .connected)
    }

    /// A remote machine's daemon (SSH, server) keeps its route, so a second connection to that
    /// daemon (an agent chat on that machine, `agent-session-attach-v1`) dials the same socket.
    @Test func aRemoteDaemonKeepsItsRouteForSecondConnections() async throws {
        let service = DaemonService(machineID: "server-test")
        #expect(service.remoteEndpoint == nil)
        service.start(remote: { "/tmp/cmux-remote-route-test.sock" })
        defer { service.shutdownConnection() }
        // Two statements: `try await #require(x)()` crashes the Xcode 27 type checker.
        let route = try #require(service.remoteEndpoint)
        let endpoint = try await route()
        #expect(endpoint.socketPath == "/tmp/cmux-remote-route-test.sock")
    }
}
