import CmuxNextDaemon
import CmuxNextSidebar
import Foundation
import Synchronization
import Testing
@testable import CmuxNextApp

/// A Cloud machine whose cmux-tui is too old for this app. The sidebar must
/// say so instead of "Connecting…" forever, and once the machine's daemon is
/// updated in place (its link socket stays), the app must connect without a
/// relaunch.
@MainActor @Suite(.timeLimit(.minutes(1))) struct RemoteMachineCompatTests {
    nonisolated static let required = DaemonCapabilities.required

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

    func waitUntil(_ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: .seconds(10))
        while !condition(), clock.now < end { try await clock.sleep(for: .milliseconds(20)) } // test-only wait
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

        try await waitUntil { service.startup.isUnavailable }
        #expect(service.startup == .unavailable(.missingCapabilities(["view-attachment-detach-v1"])))
        let header = SidebarBridge.machine(for: service, name: "vm", kind: .cloud)
        #expect(header.status != .connecting, "an incompatible machine must not look like it is still connecting")
        #expect(header.status == .updateRequired)
        #expect(header.detail?.contains("view-attachment-detach-v1") == true)
        #expect(service.compatibility?.level == .incompatible)

        // The machine is updated in place: same link socket, newer daemon.
        updated.withLock { $0 = true }
        service.retryWake.fire()
        try await waitUntil { if case .connected = service.store.connectionState { true } else { false } }
        guard case .connected = service.store.connectionState else {
            Issue.record("the updated machine never connected: \(service.store.connectionState)")
            return
        }
        // Connected with the required set only: the optional features stay
        // off and the header offers the update instead of hiding it.
        #expect(service.compatibility?.level == .limited)
        #expect(service.compatibility?.missingOptional == DaemonCapabilities.optional)
        #expect(SidebarBridge.machine(for: service, name: "vm", kind: .cloud).status == .updateAvailable)
        #expect(SidebarBridge.machine(for: service, name: "vm", kind: .local).status == .connected)
    }
}
