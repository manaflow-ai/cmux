import CmuxNextSettings
import Testing

/// `computerUse.groundingFallback` (off by default) and `computerUse.groundingEndpoint`: the helper
/// gets an endpoint only when the person turned the fallback on, and only https or http to this Mac.
struct ComputerUseGroundingSettingTests {
    private func settings(_ computerUse: [String: JSONValue]) -> ComputerUseSettings {
        CmuxConfigSnapshot.parse(.object(["computerUse": .object(computerUse)]), validDensities: [], validMetrics: [])
            .computerUse
    }

    @Test func offByDefaultSoNoEndpointReachesTheHelper() {
        let value = settings([:])
        #expect(value.groundingFallback == false)
        #expect(value.groundingEndpoint == "http://127.0.0.1:8080/v1")
        #expect(value.groundingEndpointURL == nil)
    }

    @Test func onUsesTheLocalDefault() {
        #expect(settings(["groundingFallback": true]).groundingEndpointURL?.absoluteString == "http://127.0.0.1:8080/v1")
    }

    @Test(arguments: [
        ("https://gpu.example.ts.net/v1", true), ("http://localhost:9000/v1", true),
        ("http://gpu.example.ts.net/v1", false), ("https://user:pw@gpu.example/v1", false), ("not a url", false),
    ])
    func onlyHTTPSOrThisMac(endpoint: String, accepted: Bool) {
        let value = settings(["groundingFallback": true, "groundingEndpoint": .string(endpoint)])
        #expect((value.groundingEndpointURL != nil) == accepted)
    }
}
