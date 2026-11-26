import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite
struct IrohMacSwitchRecoveryTests {
    /// Recovery is redialing a dead foreground Mac when the user opens
    /// another Mac. The switch owns the connection from then on: recovery
    /// must stand down instead of dialing the switch's target itself, which
    /// retired the switch's dial and failed the switch.
    @Test
    func macSwitchDuringRecoveryKeepsTheSwitchedMac() async throws {
        let macA = try macDialCandidate(deviceID: "mac-a", endpointByte: "a")
        let macB = try macDialCandidate(deviceID: "mac-b", endpointByte: "b")
        let fixture = try await MacDialFixture.make(macs: [macA, macB], discovered: [])
        defer { fixture.cleanup() }
        let routerA = try fixture.router(for: macA)
        let routerB = try fixture.router(for: macB)
        try await fixture.save(macA, active: true)
        #expect(await fixture.shell.reconnectActiveMacIfAvailable(stackUserID: "user-1"))
        #expect(try await pollUntil { fixture.shell.lastSuccessfulTerminalSubscription != nil })
        let clientA = try #require(fixture.shell.remoteClient)
        try await fixture.save(macB, active: false)

        // Recovery's redial of A and the switch's first dial of B stay
        // unanswered until the test releases them.
        let nextStatusA = await routerA.count(of: "mobile.host.status") + 1
        await routerA.delayHostStatusRequest(number: nextStatusA)
        await routerB.delayHostStatusRequest(number: 1)
        fixture.shell.recoverClosedControlSession(trigger: .liveness, expectedClient: clientA)
        let recoveryDialingA = try await pollUntil {
            await routerA.heldRequestCount() == 1
        }
        let switchTask = Task { @MainActor in
            await fixture.shell.switchToMac(macDeviceID: macB.deviceID)
        }
        let switchDialingB = try await pollUntil {
            await routerB.heldRequestCount() == 1
        }
        // Recovery's attempt deadline may expire while the switch dials.
        fixture.reconnectDeadlines.expirePending()
        let recoveryFailedDuringSwitch = fixture.shell.connectionRecoveryFailed
        await routerB.releaseAllHeld()
        let switched = await switchTask.value
        let recoverySettled = try await pollUntil {
            !fixture.shell.connectionRecoveryOwner.isActive
        }
        await routerA.releaseAllHeld()

        #expect(recoveryDialingA)
        #expect(switchDialingB)
        #expect(!recoveryFailedDuringSwitch, "recovery must stand down while the switch owns the connection")
        #expect(switched, "the switch's own dial must connect the Mac the user opened")
        #expect(fixture.shell.foregroundMacDeviceID == macB.deviceID)
        #expect(fixture.shell.connectionState == .connected)
        #expect(recoverySettled)
        #expect(!fixture.shell.connectionRecoveryFailed)
        #expect(fixture.factory.attemptedRouteIDs().filter { $0 == macB.routes[0].id }.count == 1,
                "only the switch dials the Mac the user opened")
    }
}
