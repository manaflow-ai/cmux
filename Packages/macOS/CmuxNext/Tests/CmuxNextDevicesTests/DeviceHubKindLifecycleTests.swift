@testable import CmuxNextDevices
import Foundation
import Testing

@MainActor @Suite(.timeLimit(.minutes(1))) struct DeviceHubKindLifecycleTests {
    private func stub() -> StubHub {
        StubHub.routes([
            "POST /v1/devices": (200, #"{"device":{"id":"x","name":"Studio"}}"#),
            "GET /v1/devices": (200, #"{"devices":[]}"#),
        ])
    }

    private func hub(_ client: DeviceHubClient) -> DeviceHub {
        DeviceHub(client: client, socket: DeviceHubSocket(connector: FakeConnector([])),
                  secrets: MemoryRelaySecretStore(), deviceName: "Studio", now: fixedNow)
    }

    private func registrations(_ stub: StubHub) -> [RecordedRequest] {
        stub.requests.filter { $0.method == "POST" && $0.url.path == "/v1/devices" }
    }

    @Test func rapidReportsCoalesceIntoTheLatestKind() async {
        let stub = stub(), hub = hub(makeClient(stub))
        await hub.start()
        let first = hub.reportKind("macbook")
        let second = hub.reportKind("mac-mini")
        let latest = hub.reportKind("mac-studio")
        await first?.value
        await second?.value
        await latest?.value
        let sent = registrations(stub)
        #expect(sent.count == 2)
        #expect(sent.last?.jsonBody?["kind"] as? String == "mac-studio")
        await hub.stopAndWait()
    }

    @Test func stopCancelsEveryPendingReportBeforeItCanRegister() async {
        let stub = stub(), hub = hub(makeClient(stub))
        await hub.start()
        let first = hub.reportKind("macbook")
        let latest = hub.reportKind("mac-mini")
        hub.stop()
        #expect(first?.isCancelled == true)
        #expect(latest?.isCancelled == true)
        await hub.stopAndWait()
        await first?.value
        await latest?.value
        #expect(registrations(stub).count == 1)
    }

    @Test(arguments: [false, true])
    func stopOrRestartJoinsAnInFlightKindRegistration(restart: Bool) async throws {
        let stub = stub(), block = Locked(false)
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let client = DeviceHubClient(baseURL: stub.baseURL, identity: .software(),
                                    tokens: DeviceHubAccountToken {
            if block.value {
                entered.continuation.yield(())
                // Deliberately ignore cancellation, like an account provider completing an actor hop.
                for await _ in release.stream { break }
            }
            return "stack-token"
        }, session: StubHub.session, now: fixedNow)
        let hub = hub(client)
        await hub.start()
        await client.signOut()
        block.set(true)
        let first = hub.reportKind("macbook")
        var reads = entered.stream.makeAsyncIterator()
        _ = await reads.next()
        let second = hub.reportKind("mac-mini")
        let latest = hub.reportKind("mac-studio")
        // This MainActor task releases the provider only after stop/start reaches its first suspension.
        let unblock = Task { @MainActor in
            #expect(first?.isCancelled == true)
            #expect(second?.isCancelled == true)
            #expect(latest?.isCancelled == true)
            block.set(false)
            release.continuation.yield(())
        }
        if restart { await hub.start() } else { await hub.stopAndWait() }
        await unblock.value
        // The stopped worker cannot overwrite the new registration or repopulate the signed-out cache.
        let exchanges = stub.requests.filter { $0.url.path == "/v1/auth/stack" }.count
        _ = try await client.accountSession()
        #expect(stub.requests.filter { $0.url.path == "/v1/auth/stack" }.count == exchanges + (restart ? 0 : 1))
        #expect(registrations(stub).count == (restart ? 2 : 1))
        if restart { #expect(registrations(stub).last?.jsonBody?["kind"] as? String == "mac-studio") }
        await first?.value
        await second?.value
        await latest?.value
        await hub.stopAndWait()
        entered.continuation.finish()
        release.continuation.finish()
    }
}
