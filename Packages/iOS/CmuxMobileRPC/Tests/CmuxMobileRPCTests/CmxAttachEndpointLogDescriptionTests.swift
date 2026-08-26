import CMUXMobileCore
import Testing

@testable import CmuxMobileRPC

@Test func hostPortLogDescriptionNamesTheEndpoint() throws {
    let endpoint = CmxAttachEndpoint.hostPort(host: "100.71.210.41", port: 49152)
    #expect(endpoint.logDescription == "100.71.210.41:49152")
}

@Test func urlLogDescriptionIsTheURL() throws {
    let endpoint = CmxAttachEndpoint.url("wss://example.invalid/attach")
    #expect(endpoint.logDescription == "wss://example.invalid/attach")
}
