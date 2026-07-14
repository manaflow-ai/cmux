import Foundation
import Testing
@testable import CmuxSimulator

@Suite("SimulatorLifecyclePolicy")
struct SimulatorLifecyclePolicyTests {
    private let policy = SimulatorLifecyclePolicy()

    private func device(state: SimulatorDeviceState, available: Bool = true) -> SimulatorDevice {
        SimulatorDevice(
            udid: SimulatorDeviceUDID(rawValue: SimulatorFixtures.shutdownUDID)!,
            name: "cmux-emu-test",
            state: state,
            isAvailable: available,
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-5"
        )
    }

    @Test func shutdownDeviceBoots() {
        #expect(policy.openAction(for: device(state: .shutdown)) == .boot)
    }

    @Test func bootedDeviceAttaches() {
        #expect(policy.openAction(for: device(state: .booted)) == .attach)
    }

    @Test func transitionalStatesRefuse() {
        #expect(policy.openAction(for: device(state: .booting)) == .refuse(.transitioning(.booting)))
        #expect(policy.openAction(for: device(state: .shuttingDown)) == .refuse(.transitioning(.shuttingDown)))
        #expect(policy.openAction(for: device(state: .creating)) == .refuse(.transitioning(.creating)))
        #expect(policy.openAction(for: device(state: .unknown("Odd"))) == .refuse(.transitioning(.unknown("Odd"))))
    }

    @Test func unavailableDeviceRefusesEvenWhenBooted() {
        #expect(policy.openAction(for: device(state: .booted, available: false)) == .refuse(.unavailable))
    }

    @Test func onlyCmuxBootedDevicesShutDownOnClose() {
        #expect(policy.shouldShutdownOnClose(ownership: .bootedByCmux))
        #expect(!policy.shouldShutdownOnClose(ownership: .attachedToRunningDevice))
    }
}

@Suite("SimulatorDeviceSession")
struct SimulatorDeviceSessionTests {
    private let udid = SimulatorDeviceUDID(rawValue: SimulatorFixtures.shutdownUDID)!

    @Test func opensShutdownDeviceByBootingAndOwnsShutdown() async throws {
        let runner = RecordingSimctlRunner(responses: [
            .init(matching: ["list"], data: SimulatorFixtures.singleDevice(udid: udid.rawValue, state: "Shutdown")),
            .init(matching: ["boot"], data: Data()),
            .init(matching: ["bootstatus"], data: Data()),
            .init(matching: ["shutdown"], data: Data()),
        ])
        let session = SimulatorDeviceSession(udid: udid, runner: runner)
        let ownership = try await session.open()
        #expect(ownership == .bootedByCmux)
        #expect(await session.currentOwnership == .bootedByCmux)

        try await session.close()
        let invocations = await runner.recordedInvocations
        #expect(invocations.contains(["boot", udid.rawValue]))
        #expect(invocations.contains(["bootstatus", udid.rawValue]))
        #expect(invocations.contains(["shutdown", udid.rawValue]))
        // The isolation invariant: nothing ever addresses the "booted" alias.
        #expect(!invocations.contains(where: { $0.contains("booted") }))
    }

    @Test func attachesToBootedDeviceAndNeverShutsItDown() async throws {
        let runner = RecordingSimctlRunner(responses: [
            .init(matching: ["list"], data: SimulatorFixtures.singleDevice(udid: udid.rawValue, state: "Booted")),
        ])
        let session = SimulatorDeviceSession(udid: udid, runner: runner)
        let ownership = try await session.open()
        #expect(ownership == .attachedToRunningDevice)

        try await session.close()
        let invocations = await runner.recordedInvocations
        #expect(!invocations.contains(where: { $0.first == "boot" }))
        #expect(!invocations.contains(where: { $0.first == "shutdown" }))
    }

    @Test func missingDeviceThrowsNotFound() async {
        let runner = RecordingSimctlRunner(responses: [
            .init(matching: ["list"], data: SimulatorFixtures.singleDevice(
                udid: SimulatorFixtures.bootedUDID, state: "Booted"
            )),
        ])
        let session = SimulatorDeviceSession(udid: udid, runner: runner)
        await #expect(throws: SimulatorSessionError.deviceNotFound(udid)) {
            try await session.open()
        }
    }

    @Test func transitioningDeviceRefuses() async {
        let runner = RecordingSimctlRunner(responses: [
            .init(matching: ["list"], data: SimulatorFixtures.singleDevice(udid: udid.rawValue, state: "Booting")),
        ])
        let session = SimulatorDeviceSession(udid: udid, runner: runner)
        await #expect(throws: SimulatorSessionError.deviceNotOpenable(.transitioning(.booting))) {
            try await session.open()
        }
        #expect(await runner.recordedInvocations.count == 1)
    }

    @Test func lostBootRaceDowngradesToAttach() async throws {
        let runner = RecordingSimctlRunner(responses: [
            .init(matching: ["list"], data: SimulatorFixtures.singleDevice(udid: udid.rawValue, state: "Shutdown")),
            .init(matching: ["boot"], failure: SimctlCommandFailure(
                arguments: ["boot", udid.rawValue],
                exitCode: 149,
                standardErrorText: "Unable to boot device in current state: Booted"
            )),
        ])
        // The re-check after the failed boot sees the device booted by someone else.
        await runner.addResponse(.init(
            matching: ["list"],
            data: SimulatorFixtures.singleDevice(udid: udid.rawValue, state: "Booted")
        ))
        let session = SimulatorDeviceSession(udid: udid, runner: runner)
        let ownership = try await session.open()
        #expect(ownership == .attachedToRunningDevice)

        try await session.close()
        let invocations = await runner.recordedInvocations
        #expect(!invocations.contains(where: { $0.first == "shutdown" }))
        #expect(!invocations.contains(where: { $0.first == "bootstatus" }))
    }

    @Test func closeWithoutOpenTouchesNothing() async throws {
        let runner = RecordingSimctlRunner(responses: [])
        let session = SimulatorDeviceSession(udid: udid, runner: runner)
        try await session.close()
        #expect(await runner.recordedInvocations.isEmpty)
    }
}
