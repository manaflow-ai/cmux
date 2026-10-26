#if DEBUG || CMUX_BENCH_HOOKS
@testable import CmuxNextControl
import CmuxNextOracle
import CmuxNextSettings
import Testing

/// The oracle's topology facet (p15-oracle-033) is the `snapshot.get` result as is: on 20 published states the
/// facet equals `snapshot.get`; a stale snapshot is built first, as `snapshot.get` builds it; a server that
/// registers the oracle with its snapshot store provides the facet. Run: `swift test --filter OracleTopologyFacetTests`.
@MainActor @Suite(.serialized) struct OracleTopologyFacetTests {
    @MainActor final class Host: OracleHost {
        func makeOracleFacets() -> OracleFacets { OracleFacets([]) }
    }

    private func router() -> ControlRouter {
        let router = ControlRouter(identity: testIdentity(), executor: CountingExecutor(),
                                   configuration: .init(requestDeadline: .seconds(30), allowsDebugMethods: true))
        router.register(OracleControl(host: Host(), snapshots: router.snapshots).methods)
        return router
    }

    private func topologyFacet(_ router: ControlRouter) async throws -> JSONValue? {
        let reply = try await router.handle(ControlRequest(id: "o", method: OracleControl.snapshot, params: ["facets": ["topology"]])).get()
        return reply["topology"]
    }

    private func snapshotGet(_ router: ControlRouter) async throws -> JSONValue {
        try await router.handle(ControlRequest(id: "s", method: "snapshot.get", params: [:])).get()
    }

    /// State `index`: a sequence, 1 + index % 3 workspaces of 1 + index % 4 tabs each, the focus on the last one.
    private static func state(_ index: Int) -> ControlTopology {
        var topology = ControlTopology()
        topology.isLoaded = true
        topology.daemonState = index.isMultiple(of: 7) ? "connecting" : "connected"
        topology.daemonSequence = UInt64(index * 3)
        topology.workspaces = (0...(index % 3)).map { workspace in
            let tabs = (0...(index % 4)).map { tab in
                ControlTabInfo(id: "tab-\(workspace)-\(tab)", surface: "\(10 + tab)", kind: tab.isMultiple(of: 2) ? "terminal" : "browser",
                               title: "t\(tab)", columns: 80, rows: 24, cwd: "/tmp")
            }
            let pane = ControlPaneInfo(id: "pane-\(workspace)", handle: "\(100 + workspace)", selectedTabID: tabs.last?.id, tabs: tabs)
            return ControlWorkspaceInfo(id: "ws-\(workspace)", handle: "\(workspace)", name: "W\(workspace)",
                                        screens: [ControlScreenInfo(id: "screen-\(workspace)", handle: "\(200 + workspace)", panes: [pane])])
        }
        let last = topology.workspaces.count - 1
        topology.windows = [ControlWindowInfo(id: "win-1", workspaceID: "ws-\(last)", isKey: true, isVisible: true, focusedPaneID: "pane-\(last)")]
        topology.focus = ControlFocus(windowID: "win-1", workspaceID: "ws-\(last)", paneID: "pane-\(last)", tabID: "tab-\(last)-\(index % 4)")
        return topology
    }

    @Test func theFacetEqualsSnapshotGetOnTwentyStates() async throws {
        let router = router()
        for index in 0..<20 {
            let state = Self.state(index)
            router.snapshots.publish(rebuilt: true) { $0.topology = state }
            let facet = try #require(try await topologyFacet(router))
            let get = try await snapshotGet(router)
            #expect(facet == get, "state \(index)")
            #expect(facet["sequence"] == JSONValue(index * 3))
            #expect(facet["caller"] == nil && facet["beside"] == nil)
        }
    }

    @Test func aStaleSnapshotIsBuiltBeforeTheFacetReadsIt() async throws {
        let router = router()
        let before = Self.state(1)
        router.snapshots.publish(rebuilt: true) { $0.topology = before }
        let store = router.snapshots
        let rebuilt = Self.state(5)
        store.setRefresher { store.publish(rebuilt: true) { $0.topology = rebuilt } }
        store.markStale()
        let facet = try #require(try await topologyFacet(router))
        #expect(facet["sequence"] == JSONValue(15), "the facet answered the topology from before the change")
        let get = try await snapshotGet(router)
        #expect(facet == get)
    }

    @Test func theServerProvidesTheTopologyFacet() async throws {
        let list = try await router().handle(ControlRequest(id: "l", method: OracleControl.snapshot, params: ["list": true])).get()
        let topology = list.arrayValue?.first { $0["facet"] == "topology" }
        #expect(topology?["provided"] == true)
        #expect(topology?["task"] == "p15-oracle-033")
    }

    @Test func addingKeepsTheHostsProvider() throws {
        let host = OracleFacetSource(.topology, .mainActor { () throws(OracleFacetError) -> OracleValue in ["from": "host"] })
        let facets = OracleFacets([host]).adding([OracleTopologyFacet(snapshots: ControlSnapshotStore())])
        #expect(facets.duplicates == [.topology])
        let snapshot = try #require(try facets.beginCapture([.topology]).completed)
        #expect(snapshot["topology"]?["from"] == "host")
    }
}
#endif
