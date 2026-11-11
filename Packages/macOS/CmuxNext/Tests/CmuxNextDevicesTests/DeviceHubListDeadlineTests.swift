@testable import CmuxNextDevices
import CmuxNextWakeupsTestSupport
import Foundation
import Observation
import Testing

/// A connector whose connect never finishes until its task is cancelled: a socket that never connects.
private struct NeverConnects: DeviceHubSocketConnector {
    func connect() async throws -> any DeviceHubSocketConnection {
        // The socket's own clock is never advanced: this sleep ends only when the hub stops the socket.
        try await ManualClock().sleep(for: .seconds(3_600))
        throw CancellationError()
    }
}

/// ui-state-fixes round 2 (verifier M-3): a hub registered but whose socket never connected never
/// read its device list, and Your Devices said "Loading your devices…" forever. Past the deadline
/// `devicesListTimedOut` is set (the page's error with Try Again); Try Again loads again under a
/// fresh deadline and a read clears it.
@MainActor @Suite struct DeviceHubListDeadlineTests {
    let me = DeviceIdentity.software()

    private func hub(_ stub: StubHub, clock: ManualClock) -> DeviceHub {
        DeviceHub(client: makeClient(stub, identity: me), socket: DeviceHubSocket(connector: NeverConnects()),
                  secrets: MemoryRelaySecretStore(), deviceName: "Studio", now: fixedNow, clock: clock)
    }

    /// Resumes at the next change of what `read` reads.
    private func nextChange(_ read: @escaping @MainActor () -> Void) -> AsyncStream<Void> {
        let (changes, change) = AsyncStream<Void>.makeStream()
        withObservationTracking { read() } onChange: { change.yield() }
        return changes
    }

    @Test func aSocketThatNeverConnectsEndsInTheErrorAndTryAgainReadsTheList() async throws {
        let me = self.me
        let stub = StubHub.routes([
            "POST /v1/devices": (200, #"{"device":{"id":"\#(me.id)","name":"Studio"}}"#),
            "GET /v1/devices": (200, devicesJSON([(me, "Studio")])),
        ])
        let clock = ManualClock()
        let hub = hub(stub, clock: clock)
        await hub.start()
        defer { hub.stop() }
        #expect(hub.status == .ready && !hub.devicesListed && !hub.devicesListTimedOut)
        try await clock.waitForSleeper()
        let changes = nextChange { _ = hub.devicesListTimedOut }
        clock.advance(by: DeviceHub.devicesListDeadline)
        for await _ in changes { break }
        #expect(hub.devicesListTimedOut, "a list never read was still loading past its deadline")

        await hub.retryDevices()
        #expect(hub.devicesListed && !hub.devicesListTimedOut && hub.devicesListError == nil)
        // The read ended the retry's deadline.
        #expect(clock.sleeperCount == 0)
    }

    @Test func tryAgainLoadsAgainUnderAFreshDeadline() async throws {
        let me = self.me
        let stub = StubHub.routes(["POST /v1/devices": (200, #"{"device":{"id":"\#(me.id)","name":"Studio"}}"#)])
        let clock = ManualClock()
        let hub = hub(stub, clock: clock)
        await hub.start()
        defer { hub.stop() }
        try await clock.waitForSleeper()
        var changes = nextChange { _ = hub.devicesListTimedOut }
        clock.advance(by: DeviceHub.devicesListDeadline)
        for await _ in changes { break }
        #expect(hub.devicesListTimedOut)

        // The read fails (no route): an error at once, not loading.
        await hub.retryDevices()
        #expect(hub.devicesListError != nil)
        // The retry armed a fresh deadline (it cleared the timeout while its read was out).
        try await clock.waitForSleeper()
        changes = nextChange { _ = hub.devicesListTimedOut }
        clock.advance(by: DeviceHub.devicesListDeadline)
        for await _ in changes { break }
        #expect(hub.devicesListTimedOut)
    }

    @Test func stopEndsTheDeadline() async throws {
        let me = self.me
        let stub = StubHub.routes(["POST /v1/devices": (200, #"{"device":{"id":"\#(me.id)","name":"Studio"}}"#)])
        let clock = ManualClock()
        let hub = hub(stub, clock: clock)
        await hub.start()
        try await clock.waitForSleeper()
        hub.stop()
        #expect(clock.sleeperCount == 0 && !hub.devicesListTimedOut)
    }
}
