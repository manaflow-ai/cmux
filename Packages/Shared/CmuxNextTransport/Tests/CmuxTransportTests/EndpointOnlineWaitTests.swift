import CmuxNextTransport
import Testing

@Suite("Native endpoint readiness deadlines", .timeLimit(.minutes(1)))
struct EndpointOnlineWaitTests {
    @Test("An unreachable relay does not make the timeout join the FFI wait")
    func unreachableRelay() async throws {
        let endpoint = try await IrohSubstrate().endpoint(
            identity: .generate(appIdentity: "test.online", deviceID: "host"),
            relays: [.init(url: "https://127.0.0.1:9/")])
        let waiter = IrohEndpointOnlineWait(endpoint: endpoint)
        let online = await waiter.value(timeout: .milliseconds(25))
        #expect(!online)
        #expect(!endpoint.isClosed())
        _ = try await endpoint.removeRelay(url: "https://127.0.0.1:9/")
        waiter.cancel()
        try await endpoint.close()
    }
}
