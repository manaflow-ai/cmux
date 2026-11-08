import Testing
@testable import CMUXMobileCore

@Test func relayPathHintsAcceptOnlyCredentialFreeRootHTTPSURLs() throws {
    let valid = try CmxIrohPathHint(
        kind: .relayURL,
        value: "https://use1-1.relay.lawrence.cmux.iroh.link/",
        source: .native,
        privacyScope: .publicInternet
    )
    #expect(valid.use == .primary)

    for unsafe in [
        "http://relay.example.test/",
        "https://user:secret@relay.example.test/",
        "https://relay.example.test/admin",
        "https://relay.example.test/?token=secret",
        "https://169.254.169.254/",
        "https://169.254.42.7/",
        "https://10.0.0.1/",
        "https://127.0.0.1/",
        "https://[::1]/",
        "https://[fd7a:115c:a1e0::1]/",
        "https://relay.local/",
        "https://0177.0.0.1/",
        "https://0x7f.0.0.1/",
        "https://127.1/",
        "https://localhost./",
        "https://relay..example.test/",
        "https://-relay.example.test/",
        "https://relay.example-.test/",
        "https://relay.example.123/",
        "relay.example.test",
    ] {
        #expect(throws: CmxIrohPathHintError.unsafeRelayURL) {
            _ = try CmxIrohPathHint(
                kind: .relayURL,
                value: unsafe,
                source: .native,
                privacyScope: .publicInternet
            )
        }
    }

    #expect(throws: CmxIrohPathHintError.relayHintRequiresNativePublicSource) {
        _ = try CmxIrohPathHint(
            kind: .relayURL,
            value: "https://relay.example.test/",
            source: .native,
            privacyScope: .privateNetwork
        )
    }
    #expect(throws: CmxIrohPathHintError.relayHintRequiresNativePublicSource) {
        _ = try CmxIrohPathHint(
            kind: .relayIdentifier,
            value: "use1",
            source: .tailscale,
            privacyScope: .privateNetwork
        )
    }
}
