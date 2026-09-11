import Foundation
import Testing

@testable import CmuxMobileShell

// Regression coverage for the launch reconnect supersede storm seen in field
// diagnostics: a presence-push recovery and the stored-Mac launch restore both
// enter `reconnectActiveMacOutcome` within milliseconds, the second claim
// cancels the first's in-flight dial, and both callers settle as
// "Superseded by a newer attempt" instead of one of them connecting. An
// automatic request that arrives while a stored-Mac attempt is already in
// flight must share that attempt's outcome, not replace it.
@MainActor
@Suite
struct StoredMacReconnectJoinTests {
    private func makeComposite(
        pairedMacStore: DelayedTeamPairedMacStore
    ) -> MobileShellComposite {
        MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedMacStore,
            identityProvider: StaticIdentityProvider(userID: "account-a"),
            reachability: AlwaysOnlineReachability(),
            pairingHintDefaults: UserDefaults(
                suiteName: "stored-mac-join-\(UUID().uuidString)"
            )!
        )
    }

    @Test
    func automaticReconnectJoinsInFlightAttemptInsteadOfSuperseding() async {
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: [:],
            blockedTeams: [""]
        )
        let composite = makeComposite(pairedMacStore: pairedStore)
        let initialGeneration = composite.storedMacReconnectGeneration

        let first = Task { @MainActor in
            await composite.reconnectActiveMacOutcome(stackUserID: "account-a")
        }
        // The first attempt is parked inside the gated store read, exactly the
        // window where a second trigger (presence push vs launch restore)
        // arrives in the field.
        await pairedStore.waitUntilLoadStarted(teamID: nil)
        let second = Task { @MainActor in
            await composite.reconnectActiveMacOutcome(stackUserID: "account-a")
        }
        // Let the second entry run to its first suspension so it has either
        // joined the in-flight attempt or (the regression) claimed a new
        // generation that supersedes the first.
        for _ in 0 ..< 50 { await Task.yield() }

        // The second automatic request must not claim a fresh generation: a
        // fresh claim is what cancels the in-flight dial.
        #expect(composite.storedMacReconnectGeneration == initialGeneration + 1)

        await pairedStore.release(teamID: nil)
        // Under the regression the second attempt blocks on its own gated
        // store read; release it too so the test settles either way.
        for _ in 0 ..< 50 { await Task.yield() }
        await pairedStore.release(teamID: nil)

        let firstOutcome = await first.value
        let secondOutcome = await second.value

        #expect(firstOutcome == secondOutcome)
        #expect(firstOutcome != .superseded)
        #expect(secondOutcome != .superseded)
    }

    @Test
    func forcedReconnectStillReplacesInFlightAttempt() async {
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: [:],
            blockedTeams: [""]
        )
        let composite = makeComposite(pairedMacStore: pairedStore)
        let initialGeneration = composite.storedMacReconnectGeneration

        let first = Task { @MainActor in
            await composite.reconnectActiveMacOutcome(stackUserID: "account-a")
        }
        await pairedStore.waitUntilLoadStarted(teamID: nil)
        let second = Task { @MainActor in
            await composite.reconnectActiveMacOutcome(
                stackUserID: "account-a",
                force: true
            )
        }
        for _ in 0 ..< 50 { await Task.yield() }

        // A forced entry (manual retry, connection-method change) claims its
        // own generation so it can replace a possibly wedged attempt.
        #expect(composite.storedMacReconnectGeneration == initialGeneration + 2)

        await pairedStore.release(teamID: nil)
        for _ in 0 ..< 50 { await Task.yield() }
        await pairedStore.release(teamID: nil)

        let firstOutcome = await first.value
        _ = await second.value

        #expect(firstOutcome == .superseded)
    }
}
