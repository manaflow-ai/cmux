import CMUXMobileCore
import Testing

@testable import CmuxMobileRPC

@Test func irohLogDescriptionNeverIncludesPeerOrRelayValues() throws {
    let peerID = String(repeating: "a", count: 64)
    let relayURL = "https://secret-relay.example.test/"
    let endpoint = CmxAttachEndpoint.peer(
        identity: try CmxIrohPeerIdentity(endpointID: peerID),
        pathHints: [
            try CmxIrohPathHint(
                kind: .relayURL,
                value: relayURL,
                source: .native,
                privacyScope: .publicInternet
            ),
            try CmxIrohPathHint(
                kind: .directAddress,
                value: "8.8.8.8:49152",
                source: .native,
                privacyScope: .publicInternet
            ),
        ]
    )

    #expect(endpoint.logDescription == "peer:1-relays:1-direct-addrs")
    #expect(!endpoint.logDescription.contains(peerID))
    #expect(!endpoint.logDescription.contains(relayURL))
}
