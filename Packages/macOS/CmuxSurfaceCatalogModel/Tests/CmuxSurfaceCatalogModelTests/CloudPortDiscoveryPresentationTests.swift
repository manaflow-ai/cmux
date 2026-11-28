import Testing
@testable import CmuxSurfaceCatalogModel

@Suite struct CloudPortDiscoveryPresentationTests {
    @Test("Reachable services do not need an extra status row", arguments: [
        CloudPortDiscoveryState.available, .loopbackOnly,
    ])
    func reachablePortsStandAlone(state: CloudPortDiscoveryState) {
        #expect(!state.keepsStatusAlongsideRows)
    }

    @Test("Incomplete scans keep their explanation beside retained ports", arguments: [
        CloudPortDiscoveryState.loading, .stale, .unavailable(.transport), .unsupported,
    ])
    func incompleteScanRemainsVisible(state: CloudPortDiscoveryState) {
        #expect(state.keepsStatusAlongsideRows)
    }
}
