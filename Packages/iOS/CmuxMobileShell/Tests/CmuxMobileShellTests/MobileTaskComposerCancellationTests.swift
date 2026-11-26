import CmuxMobilePairedMac
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileTaskComposerCancellationTests {
    @Test func cancellationInvalidatesOwnedMacSwitchBeforeLateSecondaryPromotion() async throws {
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: ["": [Self.pairedMac(macDeviceID: "secondary-current")]],
            blockedTeams: [""]
        )
        let targetRouter = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(
            router: RoutingHostRouter(),
            pairedMacStore: pairedStore
        )
        try installSecondaryClient(
            on: store,
            macDeviceID: "secondary-current",
            router: targetRouter,
            supportedHostCapabilities: ["workspace.task_create.v1"]
        )
        var boundaryCallCount = 0

        let submission = Task { @MainActor in
            await store.submitTaskComposer(
                macDeviceID: "secondary-current",
                spec: MobileWorkspaceCreateSpec(title: "Cancelled", operationID: UUID()),
                willStartCreate: { boundaryCallCount += 1 }
            )
        }
        let firstAuthorityReadStarted = try await pollUntil {
            await pairedStore.currentLoadAllCount() == 1
        }
        #expect(firstAuthorityReadStarted)
        await pairedStore.release(teamID: nil)
        let finalAuthorityReadStarted = try await pollUntil {
            await pairedStore.currentLoadAllCount() == 2
        }
        #expect(finalAuthorityReadStarted)

        submission.cancel()
        let ownedAttemptWasInvalidated = try await pollUntil {
            !store.isMacSwitchInFlight
        }
        #expect(ownedAttemptWasInvalidated)

        await pairedStore.release(teamID: nil)
        _ = await submission.value

        #expect(store.foregroundMacDeviceID == "test-mac")
        #expect(boundaryCallCount == 0)
        #expect(await targetRouter.recordedWorkspaceCreateCount() == 0)
    }

    @Test func cancellingSupersededSubmissionDoesNotCancelNewerMacSwitch() async throws {
        // Name the paired instances explicitly so both submissions exercise
        // the warm control-pool promotion path before the display cache loads.
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: ["": [
                Self.pairedMac(macDeviceID: "secondary-b", instanceTag: "b"),
                Self.pairedMac(macDeviceID: "secondary-c", instanceTag: "c"),
            ]],
            blockedTeams: [""]
        )
        let routerB = RoutingHostRouter()
        let routerC = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(
            router: RoutingHostRouter(),
            pairedMacStore: pairedStore
        )
        defer {
            // The successful switch starts a trailing aggregation pass. Stop
            // the lifecycle owner so its delayed store read receives the same
            // cancellation signal as a real background transition.
            store.suspendForegroundRefresh()
        }
        try installSecondaryClient(
            on: store,
            macDeviceID: "secondary-b",
            instanceTag: "b",
            router: routerB,
            supportedHostCapabilities: ["workspace.task_create.v1"]
        )
        try installSecondaryClient(
            on: store,
            macDeviceID: "secondary-c",
            instanceTag: "c",
            router: routerC,
            supportedHostCapabilities: ["workspace.task_create.v1"]
        )
        var boundaryBCount = 0
        var boundaryCCount = 0

        let submissionB = Task { @MainActor in
            await store.submitTaskComposer(
                macDeviceID: "secondary-b",
                instanceTag: "b",
                spec: MobileWorkspaceCreateSpec(title: "B", operationID: UUID()),
                willStartCreate: { boundaryBCount += 1 }
            )
        }
        #expect(try await pollUntil { await pairedStore.currentLoadAllCount() == 1 })
        await pairedStore.release(teamID: nil)
        #expect(try await pollUntil { await pairedStore.currentLoadAllCount() == 2 })

        let submissionC = Task { @MainActor in
            await store.submitTaskComposer(
                macDeviceID: "secondary-c",
                instanceTag: "c",
                spec: MobileWorkspaceCreateSpec(title: "C", operationID: UUID()),
                willStartCreate: { boundaryCCount += 1 }
            )
        }
        #expect(try await pollUntil { await pairedStore.currentLoadAllCount() == 3 })

        submissionB.cancel()
        #expect(store.isMacSwitchInFlight)
        _ = await submissionB.value
        #expect(store.isMacSwitchInFlight)

        await pairedStore.release(teamID: nil)
        #expect(try await pollUntil { await pairedStore.currentLoadAllCount() == 4 })
        await pairedStore.release(teamID: nil)
        let resultC = await submissionC.value

        guard case .success = resultC else {
            return #expect(Bool(false), "newer submission should retain its Mac-switch authority")
        }
        #expect(store.foregroundMacDeviceID == "secondary-c")
        #expect(boundaryBCount == 0)
        #expect(boundaryCCount == 1)
        #expect(await routerB.recordedWorkspaceCreateCount() == 0)
        #expect(await routerC.recordedWorkspaceCreateCount() == 1)
    }

    private static func pairedMac(
        macDeviceID: String,
        instanceTag: String? = nil
    ) -> MobilePairedMac {
        MobilePairedMac(
            macDeviceID: macDeviceID,
            displayName: macDeviceID,
            routes: [],
            createdAt: Date(),
            lastSeenAt: Date(),
            isActive: false,
            stackUserID: "routing-user",
            instanceTag: instanceTag
        )
    }
}
