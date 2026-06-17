import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

/// Behavior tests for ``MultiMacWorkspaceAggregator``: it fetches each online
/// Mac's `mobile.workspace.list` over a short-lived client, tags every preview
/// with the owning Mac's `deviceId`, isolates one Mac's failure from the others,
/// and prunes devices that leave the target set.
@MainActor
@Suite struct MultiMacWorkspaceAggregatorTests {
    @Test func tagsEachSliceWithItsDeviceID() async throws {
        let hosts = MultiMacScriptedHosts(byPort: [
            7001: ScriptedMacList(workspaceIDs: ["ws-a"]),
            7002: ScriptedMacList(workspaceIDs: ["ws-b"]),
        ])
        let runtime = MultiMacRuntime(transportFactory: MultiMacTransportFactory(hosts: hosts))
        let aggregator = MultiMacWorkspaceAggregator(runtime: runtime)

        await aggregator.refresh(targets: [
            .init(deviceId: "mac-1", displayName: "Mac One", route: try loopbackRoute(port: 7001)),
            .init(deviceId: "mac-2", displayName: "Mac Two", route: try loopbackRoute(port: 7002)),
        ])

        let mac1 = aggregator.workspaces(forDeviceID: "mac-1")
        let mac2 = aggregator.workspaces(forDeviceID: "mac-2")
        #expect(mac1.map(\.id.rawValue) == ["ws-a"])
        #expect(mac2.map(\.id.rawValue) == ["ws-b"])
        // Every fetched preview — and its terminals — carry the owning device id.
        #expect(mac1.allSatisfy { $0.deviceId == "mac-1" })
        #expect(mac1.flatMap(\.terminals).allSatisfy { $0.deviceId == "mac-1" })
        #expect(mac2.allSatisfy { $0.deviceId == "mac-2" })
        #expect(mac2.flatMap(\.terminals).allSatisfy { $0.deviceId == "mac-2" })
        #expect(aggregator.perDeviceError.isEmpty)
    }

    @Test func scopedIDsResolveIndependentlyWhenBareIDsCollide() async throws {
        // Two Macs report the SAME bare workspace and terminal id strings. The
        // scoped identity (deviceId + id) must keep them distinct so selection
        // and routing can target the correct Mac.
        let hosts = MultiMacScriptedHosts(byPort: [
            7101: ScriptedMacList(workspaceIDs: ["workspace-1"]),
            7102: ScriptedMacList(workspaceIDs: ["workspace-1"]),
        ])
        let runtime = MultiMacRuntime(transportFactory: MultiMacTransportFactory(hosts: hosts))
        let aggregator = MultiMacWorkspaceAggregator(runtime: runtime)

        await aggregator.refresh(targets: [
            .init(deviceId: "mac-A", displayName: "A", route: try loopbackRoute(port: 7101)),
            .init(deviceId: "mac-B", displayName: "B", route: try loopbackRoute(port: 7102)),
        ])

        let a = try #require(aggregator.workspaces(forDeviceID: "mac-A").first)
        let b = try #require(aggregator.workspaces(forDeviceID: "mac-B").first)
        // Bare ids collide on purpose...
        #expect(a.id == b.id)
        #expect(a.terminals.first?.id == b.terminals.first?.id)
        // ...but the scoped identities are distinct and route to the right Mac.
        #expect(ScopedWorkspaceID(a) != ScopedWorkspaceID(b))
        #expect(ScopedWorkspaceID(a).deviceId == "mac-A")
        #expect(ScopedWorkspaceID(b).deviceId == "mac-B")
        let aTerminal = try #require(a.terminals.first)
        let bTerminal = try #require(b.terminals.first)
        #expect(ScopedTerminalID(aTerminal) != ScopedTerminalID(bTerminal))
        #expect(ScopedTerminalID(aTerminal).deviceId == "mac-A")
        #expect(ScopedTerminalID(bTerminal).deviceId == "mac-B")
    }

    @Test func oneMacFailureDoesNotBlankOthers() async throws {
        let hosts = MultiMacScriptedHosts(byPort: [
            7201: ScriptedMacList(workspaceIDs: ["ok-1"]),
            7202: ScriptedMacList(workspaceIDs: [], fails: true),
        ])
        let runtime = MultiMacRuntime(transportFactory: MultiMacTransportFactory(hosts: hosts))
        let aggregator = MultiMacWorkspaceAggregator(runtime: runtime)

        await aggregator.refresh(targets: [
            .init(deviceId: "good", displayName: "Good", route: try loopbackRoute(port: 7201)),
            .init(deviceId: "bad", displayName: "Bad", route: try loopbackRoute(port: 7202)),
        ])

        // The healthy Mac's slice is present; the failing one records an error
        // and contributes no slice.
        #expect(aggregator.workspaces(forDeviceID: "good").map(\.id.rawValue) == ["ok-1"])
        #expect(aggregator.workspaces(forDeviceID: "bad").isEmpty)
        #expect(aggregator.perDeviceError["bad"] != nil)
        #expect(aggregator.perDeviceError["good"] == nil)
    }

    @Test func transientFailureLeavesPriorSliceIntact() async throws {
        let hosts = MultiMacScriptedHosts(byPort: [
            7301: ScriptedMacList(workspaceIDs: ["ws-x"]),
        ])
        let runtime = MultiMacRuntime(transportFactory: MultiMacTransportFactory(hosts: hosts))
        let aggregator = MultiMacWorkspaceAggregator(runtime: runtime)
        let target = MultiMacWorkspaceAggregator.Target(
            deviceId: "mac",
            displayName: "Mac",
            route: try loopbackRoute(port: 7301)
        )

        await aggregator.refresh(targets: [target])
        #expect(aggregator.workspaces(forDeviceID: "mac").map(\.id.rawValue) == ["ws-x"])

        // The Mac now fails. A refresh records the error but must NOT blank the
        // last-known-good slice.
        await hosts.setList(port: 7301, list: ScriptedMacList(workspaceIDs: [], fails: true))
        await aggregator.refresh(targets: [target])
        #expect(aggregator.perDeviceError["mac"] != nil)
        #expect(aggregator.workspaces(forDeviceID: "mac").map(\.id.rawValue) == ["ws-x"])
    }

    @Test func prunesDevicesThatLeaveTargetSet() async throws {
        let hosts = MultiMacScriptedHosts(byPort: [
            7401: ScriptedMacList(workspaceIDs: ["ws-1"]),
            7402: ScriptedMacList(workspaceIDs: ["ws-2"]),
        ])
        let runtime = MultiMacRuntime(transportFactory: MultiMacTransportFactory(hosts: hosts))
        let aggregator = MultiMacWorkspaceAggregator(runtime: runtime)

        await aggregator.refresh(targets: [
            .init(deviceId: "mac-1", displayName: "1", route: try loopbackRoute(port: 7401)),
            .init(deviceId: "mac-2", displayName: "2", route: try loopbackRoute(port: 7402)),
        ])
        #expect(aggregator.workspaces(forDeviceID: "mac-1").isEmpty == false)
        #expect(aggregator.workspaces(forDeviceID: "mac-2").isEmpty == false)

        // mac-2 leaves the target set (went offline / became active). Its slice
        // is pruned; mac-1 stays.
        await aggregator.refresh(targets: [
            .init(deviceId: "mac-1", displayName: "1", route: try loopbackRoute(port: 7401)),
        ])
        #expect(aggregator.workspaces(forDeviceID: "mac-1").isEmpty == false)
        #expect(aggregator.workspaces(forDeviceID: "mac-2").isEmpty)
        #expect(aggregator.perDeviceWorkspaces["mac-2"] == nil)
    }

    @Test func resetClearsAllState() async throws {
        let hosts = MultiMacScriptedHosts(byPort: [
            7501: ScriptedMacList(workspaceIDs: ["ws-1"]),
        ])
        let runtime = MultiMacRuntime(transportFactory: MultiMacTransportFactory(hosts: hosts))
        let aggregator = MultiMacWorkspaceAggregator(runtime: runtime)

        await aggregator.refresh(targets: [
            .init(deviceId: "mac-1", displayName: "1", route: try loopbackRoute(port: 7501)),
        ])
        #expect(aggregator.perDeviceWorkspaces.isEmpty == false)

        aggregator.reset()
        #expect(aggregator.perDeviceWorkspaces.isEmpty)
        #expect(aggregator.perDeviceError.isEmpty)
    }

    @Test func nilRuntimeIsInert() async throws {
        let aggregator = MultiMacWorkspaceAggregator(runtime: nil)
        await aggregator.refresh(targets: [
            .init(deviceId: "mac-1", displayName: "1", route: try loopbackRoute(port: 7601)),
        ])
        #expect(aggregator.perDeviceWorkspaces.isEmpty)
        #expect(aggregator.perDeviceError.isEmpty)
    }
}
