import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextDaemon
import Foundation
import Testing

/// Reopen Closed Tab for a tab on a Cloud machine: the close is recorded
/// from that machine's store, and the reopen goes to that machine's daemon
/// and pane, never to the local daemon.
@MainActor
struct ReopenClosedCloudTabTests {
    /// A Cloud machine session that never connects (its store is fed below).
    static func cloudSession(_ id: String) -> CloudMachineSession {
        let configuration = CloudConfiguration.resolve(bundleID: nil, bundled: [:], process: [:], isDebugBuild: true)
        let api = CloudAPIClient(configuration: configuration, tokens: { throw CancellationError() }, teamID: { nil })
        let paths = CloudPaths(root: URL(fileURLWithPath: "/tmp/cna-cloud-\(id)"))
        let binary = URL(fileURLWithPath: "/nonexistent/cmux-tui")
        let hub = CloudTunnelHub(api: api, paths: paths, binary: binary, deviceName: "test")
        let link = CloudMachineLink(machineID: id, api: api, hub: hub, paths: paths, binary: binary, deviceName: "test")
        return CloudMachineSession(machine: CloudMachine(id: id), link: link)
    }

    @Test func closedCloudTerminalTabReopensOnItsMachine() async throws {
        let services = ActionBindingCoverageTests.boundServices()
        let calls = ReopenClosedTabTests.Calls()
        let tracker = try #require(services.closedTabs)
        tracker.restorer = ClosedTerminalRestorer(
            isAvailable: { true },
            project: { terminal, path, index in
                calls.projected.append((terminal, path, index))
                return ResourceID(rawValue: "tab_restored")
            },
            spawn: { spawn in
                calls.spawned.append(spawn)
                return SurfaceID(rawValue: 99)
            })
        let session = Self.cloudSession("vm-0123456789abcdef0123456789abcdef")
        services.machines.add(session)
        let store = session.daemon.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(ReopenClosedTabTests.identify.utf8))
        _ = store.apply(.connected(identity, generationChanged: false))
        store.apply(snapshot: try ReopenClosedTabTests.tree([ReopenClosedTabTests.tab(1, "a", cwd: "/root/a"),
                                                             ReopenClosedTabTests.tab(2, "b", cwd: "/root/b")]))
        await ReopenClosedTabTests.settle { false }
        store.apply(snapshot: try ReopenClosedTabTests.tree([ReopenClosedTabTests.tab(1, "a", cwd: "/root/a")]))
        await ReopenClosedTabTests.settle { false }

        let work = services.registry.capturingWork {
            _ = services.registry.perform("reopenClosedBrowserPanel", invocation: ActionInvocation())
        }
        for task in work { #expect(await task.value == nil) }
        #expect(calls.projected.count == 1, "the Cloud tab's close was not recorded or not reopened")
        let (terminal, _, index) = try #require(calls.projected.first)
        #expect(terminal == ResourceID(rawValue: "term_b"))
        #expect(index == 1)
    }
}
