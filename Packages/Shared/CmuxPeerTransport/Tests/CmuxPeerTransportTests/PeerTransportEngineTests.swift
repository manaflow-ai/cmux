import Testing

@testable import CmuxPeerTransport

@Suite struct PeerTransportEngineTests {
    @Test func engineTypeExists() {
        _ = PeerTransportEngine.self
    }
}
