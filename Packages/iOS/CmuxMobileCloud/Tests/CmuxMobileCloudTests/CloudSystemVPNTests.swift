import Testing
@testable import CmuxMobileCloud

@MainActor
@Suite struct CloudSystemVPNTests {
    private func signedIn(_ rig: Rig, scope: String = "user-1/team-1") async {
        rig.controller.setScope(scope)
        await rig.controller.waitForPendingOperation()
    }

    @Test func enablingEnrollsAPrivateBrowserPeerWithItsOwnKey() async throws {
        let rig = Rig()
        await signedIn(rig)
        rig.controller.enable()
        #expect(rig.controller.phase == .preparing)
        await rig.controller.waitForPendingOperation()

        let enroll = try #require(rig.service.calls.enroll.first)
        #expect(enroll.purpose == .browser)
        #expect(enroll.deviceName == "Aziz's iPhone")
        // Filed under the same device as the terminal tunnel...
        guard case .found(let identity) = await rig.store.read() else {
            Issue.record("device identity was not persisted")
            return
        }
        #expect(enroll.fingerprint == identity.fingerprint)
        // ...but as a separate peer: the terminal tunnel's key never travels
        // for the VPN, so the two peers never contend for one key.
        #expect(enroll.publicKey != identity.keyPair.publicKey)

        let install = try #require(rig.manager.installed.first)
        #expect(install.scope == "user-1/team-1")
        #expect(!install.configuration.contains(identity.keyPair.privateKey))
        #expect(install.configuration.contains("PrivateKey = "))
        #expect(install.configuration.contains("AllowedIPs = 10.0.0.0/8, fd00::/8"))
        #expect(rig.controller.phase == .connecting)
    }

    @Test func eachEnableMintsAFreshKey() async throws {
        let rig = Rig()
        await signedIn(rig)
        rig.controller.enable()
        await rig.controller.waitForPendingOperation()
        rig.controller.disable()
        await rig.controller.waitForPendingOperation()
        rig.controller.enable()
        await rig.controller.waitForPendingOperation()

        let keys = rig.service.calls.enroll.map(\.publicKey)
        #expect(keys.count == 2)
        #expect(Set(keys).count == 2)
    }

    @Test func aPublicRouteIsRefusedBeforeAnythingIsSaved() async {
        let rig = Rig()
        var enrollment = Fixtures.enrollment
        enrollment.routes = ["0.0.0.0/0"]
        rig.service.enrollment = .success(enrollment)
        await signedIn(rig)
        rig.controller.enable()
        await rig.controller.waitForPendingOperation()

        #expect(rig.manager.installed.isEmpty)
        #expect(rig.controller.phase == .failed(.configuration))
        #expect(rig.service.calls.revoke.count == 1)
        #expect(rig.service.calls.revoke.first?.fingerprint == "ios-abc")
        #expect(rig.service.calls.revoke.first?.purpose == .browser)
    }

    @Test func aPublicRouteInsideServerConfigTextIsRefused() async {
        let rig = Rig()
        var enrollment = Fixtures.enrollment
        // The FIELDS look private, but the server-supplied wg-quick text (the
        // artifact that actually gets installed) routes everything.
        enrollment.clientConfig = """
        [Interface]
        Address = 100.100.0.7/32
        [Peer]
        PublicKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
        Endpoint = 203.0.113.9:51820
        AllowedIPs = 10.0.0.0/8, 0.0.0.0/0
        """
        rig.service.enrollment = .success(enrollment)
        await signedIn(rig)
        rig.controller.enable()
        await rig.controller.waitForPendingOperation()

        #expect(rig.manager.installed.isEmpty)
        #expect(rig.controller.phase == .failed(.configuration))
        #expect(rig.service.calls.revoke.count == 1)
        #expect(rig.service.calls.revoke.first?.fingerprint == "ios-abc")
        #expect(rig.service.calls.revoke.first?.purpose == .browser)
    }

    @Test func enrollmentFailureIsReportedAsEnrollment() async {
        let rig = Rig()
        rig.service.enrollment = .failure(CloudAPIError.httpStatus(500, message: nil, action: nil))
        await signedIn(rig)
        rig.controller.enable()
        await rig.controller.waitForPendingOperation()

        #expect(rig.manager.installed.isEmpty)
        #expect(rig.controller.phase == .failed(.enrollment))
        #expect(rig.controller.phase != .off)
        #expect(rig.service.calls.revoke.isEmpty)
    }

    @Test func aPlatformInstallFailureRevokesANewBrowserPeer() async {
        let rig = Rig()
        rig.manager.installFailure = .permissionRequired
        await signedIn(rig)

        rig.controller.enable()
        await rig.controller.waitForPendingOperation()

        #expect(rig.controller.phase == .failed(.permissionRequired))
        #expect(rig.service.calls.revoke.count == 1)
        #expect(rig.service.calls.revoke.first?.fingerprint == "ios-abc")
        #expect(rig.service.calls.revoke.first?.purpose == .browser)
    }

    @Test func failedInstallRevocationIsStoredForLaterRetry() async {
        let pendingStore = InMemoryCloudSystemVPNPendingRevocationStore()
        let rig = Rig(
            pendingRevocationStore: pendingStore
        )
        rig.manager.installFailure = .permissionRequired
        rig.service.revocationFailure = StubError(message: "offline")
        await signedIn(rig)

        rig.controller.enable()
        await rig.controller.waitForPendingOperation()

        #expect(rig.controller.phase == .failed(.permissionRequired))
        #expect(await pendingStore.load(scope: "user-1/team-1") == ["ios-abc"])
    }

    @Test func aStalledInstallTimesOutAndLeavesTheSwitchRecoverable() async {
        let rig = Rig(operationTimeout: .milliseconds(100))
        rig.manager.installDelay = .milliseconds(500)
        await signedIn(rig)
        rig.controller.enable()
        await rig.controller.waitForPendingOperation()

        #expect(rig.controller.phase == .failed(.configuration))
        #expect(rig.manager.installed.isEmpty)

        await rig.manager.waitForCancellation()
        await rig.service.waitForRevocation()
        #expect(rig.service.calls.revoke.count == 1)
        #expect(rig.service.calls.revoke.first?.fingerprint == "ios-abc")
        #expect(rig.service.calls.revoke.first?.purpose == .browser)
    }

    @Test func timedOutCleanupReconcilesAfterRetainedStopCompletes() async {
        let rig = Rig(operationTimeout: .milliseconds(50))
        rig.manager.stopDelay = .milliseconds(80)
        await signedIn(rig)
        rig.controller.enable()
        await rig.controller.waitForPendingOperation()

        rig.controller.setScope(nil)
        await rig.controller.waitForPendingOperation()
        await rig.manager.waitForStopCompletion()

        for _ in 0..<50 where rig.controller.phase != .off {
            try? await ContinuousClock().sleep(for: .milliseconds(5))
        }
        #expect(rig.manager.stops == [true])
        #expect(rig.controller.phase == .off)
    }

    @Test func signOutTeardownRevokesTheBrowserPeerWithCapturedCredentials() async {
        let rig = Rig()
        await signedIn(rig)
        rig.controller.enable()
        await rig.controller.waitForPendingOperation()
        let teardown = rig.controller.serverTeardown()

        await teardown("captured-access", "captured-refresh")

        #expect(rig.service.calls.revoke.count == 1)
        #expect(rig.service.calls.revoke.first?.fingerprint == "ios-abc")
        #expect(rig.service.calls.revoke.first?.purpose == .browser)
    }

    @Test func signOutWithoutCapturedCredentialsPersistsBrowserRevocation() async {
        let pendingStore = InMemoryCloudSystemVPNPendingRevocationStore()
        let rig = Rig(pendingRevocationStore: pendingStore)
        await signedIn(rig)
        rig.controller.enable()
        await rig.controller.waitForPendingOperation()

        let teardown = rig.controller.serverTeardown()
        await teardown(nil, nil)

        #expect(await pendingStore.load(scope: "user-1/team-1") == ["ios-abc"])
    }

    @Test func failedSignOutRevocationIsRetriedAfterControllerRecreation() async {
        let pendingStore = InMemoryCloudSystemVPNPendingRevocationStore()
        let first = Rig(cleanupRetryCount: 1, pendingRevocationStore: pendingStore)
        await signedIn(first)
        first.controller.enable()
        await first.controller.waitForPendingOperation()
        first.service.revocationFailure = StubError(message: "offline")

        let teardown = first.controller.serverTeardown()
        first.controller.setScope(nil)
        await first.controller.waitForPendingOperation()
        await teardown("captured-access", "captured-refresh")

        #expect(await pendingStore.load(scope: "user-1/team-1") == ["ios-abc"])

        let second = Rig(pendingRevocationStore: pendingStore)
        await signedIn(second)

        #expect(second.service.calls.revoke.count == 1)
        #expect(second.service.calls.revoke.first?.fingerprint == "ios-abc")
        #expect(await pendingStore.load(scope: "user-1/team-1").isEmpty)
    }

    @Test func failedPersistedRevocationCanBeRetriedFromTheRecoveryAction() async {
        let pendingStore = InMemoryCloudSystemVPNPendingRevocationStore()
        let first = Rig(cleanupRetryCount: 1, pendingRevocationStore: pendingStore)
        await signedIn(first)
        first.controller.enable()
        await first.controller.waitForPendingOperation()
        first.service.revocationFailure = StubError(message: "offline")

        let teardown = first.controller.serverTeardown()
        first.controller.setScope(nil)
        await first.controller.waitForPendingOperation()
        await teardown("captured-access", "captured-refresh")

        let second = Rig(cleanupRetryCount: 1, pendingRevocationStore: pendingStore)
        second.service.revocationFailure = StubError(message: "offline")
        await signedIn(second)
        #expect(second.controller.phase == .failed(.configuration))

        second.service.revocationFailure = nil
        second.controller.retry()
        await second.controller.waitForPendingOperation()

        #expect(second.service.calls.revoke.count == 2)
        #expect(await pendingStore.load(scope: "user-1/team-1").isEmpty)
    }

    @Test func aTimedOutInstallCanBeReplacedAfterPlatformCancellation() async {
        let rig = Rig(operationTimeout: .milliseconds(100))
        rig.manager.installDelay = .milliseconds(500)
        await signedIn(rig)

        rig.controller.enable()
        await rig.controller.waitForPendingOperation()
        #expect(rig.controller.phase == .failed(.configuration))

        rig.controller.enable()
        await rig.manager.waitForCancellation()
        await rig.manager.waitForInstallCompletion()
        await rig.controller.waitForPendingOperation()

        #expect(rig.manager.cancelPendingOperationCount == 1)
        #expect(rig.service.calls.enroll.count == 2)
        #expect(rig.manager.maxConcurrentOperations == 1)
    }

    @Test func anAbandonedGateWaitsForTheUnderlyingCallBeforeReplacement() async throws {
        let gate = CloudSystemVPNOperationGate()
        let firstStarted = TestSignal()
        let releaseFirst = TestSignal()
        let cancellationRequested = TestSignal()
        var activeOperations = 0
        var maxConcurrentOperations = 0
        var secondStarted = false

        let first = gate.start {
            activeOperations += 1
            maxConcurrentOperations = max(maxConcurrentOperations, activeOperations)
            await firstStarted.signal()
            await releaseFirst.wait()
            activeOperations -= 1
        }
        await firstStarted.wait()

        let abandoned = first.abandonIfAcquired(after: .milliseconds(1)) {
            Task { await cancellationRequested.signal() }
        }
        #expect(abandoned)

        let second = gate.start {
            secondStarted = true
            activeOperations += 1
            maxConcurrentOperations = max(maxConcurrentOperations, activeOperations)
            activeOperations -= 1
        }

        await cancellationRequested.wait()
        #expect(!secondStarted)
        #expect(gate.hasPendingOperation)

        await releaseFirst.signal()
        try await first.result.value
        try await second.result.value

        #expect(secondStarted)
        #expect(maxConcurrentOperations == 1)
    }

    @Test func aLateInstallReconcilesAndDoesNotEnrollAgain() async {
        let rig = Rig(operationTimeout: .milliseconds(100))
        rig.manager.installDelay = .milliseconds(250)
        await signedIn(rig)

        rig.controller.enable()
        await rig.controller.waitForPendingOperation()
        #expect(rig.controller.phase == .failed(.configuration))

        rig.controller.enable()
        #expect(rig.service.calls.enroll.count == 1)

        await rig.manager.waitForInstallCompletion()
        await rig.waitForPhase(.failed(.configuration))
        #expect(rig.manager.installed.count == 1)
        #expect(rig.controller.phase == .failed(.configuration))
    }

    @Test func aLateEnrollmentContinuesIntoInstallAndDoesNotEnrollAgain() async {
        let rig = Rig(operationTimeout: .milliseconds(100))
        rig.service.enrollmentDelay = .milliseconds(250)
        await signedIn(rig)

        rig.controller.enable()
        await rig.controller.waitForPendingOperation()
        #expect(rig.controller.phase == .failed(.configuration))

        rig.controller.enable()
        #expect(rig.service.calls.enroll.count == 1)

        await rig.service.waitForEnrollmentCompletion()
        await rig.manager.waitForInstallCompletion()
        await rig.waitForPhase(.failed(.configuration))
        #expect(rig.manager.installed.count == 1)
        #expect(rig.controller.phase == .failed(.configuration))
    }

    @Test func aStaleEnrollmentIsRevokedBeforeItCanInstall() async {
        let rig = Rig(operationTimeout: .milliseconds(100))
        rig.service.enrollmentDelay = .milliseconds(250)
        await signedIn(rig)

        rig.controller.enable()
        await rig.controller.waitForPendingOperation()
        #expect(rig.controller.phase == .failed(.configuration))

        rig.controller.setScope(nil)
        await rig.service.waitForEnrollmentCompletion()
        await rig.service.waitForRevocation()
        await rig.controller.waitForPendingOperation()

        #expect(rig.manager.installed.isEmpty)
        #expect(rig.service.calls.revoke.count == 1)
        #expect(rig.service.calls.revoke.first?.fingerprint == "ios-abc")
        #expect(rig.service.calls.revoke.first?.purpose == .browser)
    }

    @Test func aStartRequestStaysTransitioningUntilStatusArrives() async {
        let rig = Rig()
        rig.manager.phaseAfterStart = .off
        await signedIn(rig)

        rig.controller.enable()
        await rig.controller.waitForPendingOperation()

        #expect(rig.controller.phase == .connecting)
        rig.controller.enable()
        #expect(rig.service.calls.enroll.count == 1)

        rig.manager.report(.connected)
        #expect(rig.controller.phase == .connected)
    }

    @Test func aStartThatNeverReportsAStableStatusFails() async {
        let rig = Rig(operationTimeout: .milliseconds(50))
        rig.manager.phaseAfterStart = .off
        await signedIn(rig)

        rig.controller.enable()
        await rig.controller.waitForPendingOperation()
        #expect(rig.controller.phase == .connecting)

        await rig.waitForPhase(.failed(.configuration))
        #expect(rig.controller.phase == .failed(.configuration))
    }

    @Test func aStopThatNeverReportsAStableStatusFails() async {
        let rig = Rig(operationTimeout: .milliseconds(50))
        await signedIn(rig)
        rig.controller.enable()
        await rig.controller.waitForPendingOperation()
        rig.manager.report(.connected)

        rig.manager.phaseAfterStop = .disconnecting
        rig.controller.disable()
        await rig.controller.waitForPendingOperation()
        #expect(rig.controller.phase == .disconnecting)

        await rig.waitForPhase(.failed(.configuration))
        #expect(rig.controller.phase == .failed(.configuration))
    }

    @Test func aQueuedReplacementTimesOutAndCanBeRetried() async {
        let rig = Rig(operationTimeout: .milliseconds(100))
        rig.manager.installDelay = .milliseconds(500)
        await signedIn(rig)

        rig.controller.enable()
        await rig.controller.waitForPendingOperation()
        #expect(rig.controller.phase == .failed(.configuration))

        rig.controller.disable()
        await rig.controller.waitForPendingOperation()

        #expect(rig.manager.maxConcurrentOperations == 1)
        #expect(rig.manager.stops.isEmpty)
        #expect(rig.controller.phase == .failed(.configuration))

        await rig.manager.waitForCancellation()
        rig.controller.disable()
        await rig.controller.waitForPendingOperation()

        #expect(rig.manager.maxConcurrentOperations == 1)
        #expect(rig.manager.stops == [false])
        #expect(rig.controller.phase == .off)
    }

    @Test func signOutCleanupStaysQueuedBehindALateInstall() async {
        let rig = Rig(operationTimeout: .milliseconds(100))
        rig.manager.installDelay = .milliseconds(500)
        await signedIn(rig)

        rig.controller.enable()
        await rig.controller.waitForPendingOperation()
        #expect(rig.controller.phase == .failed(.configuration))

        rig.controller.setScope(nil)
        await rig.controller.waitForPendingOperation()
        #expect(rig.manager.stops.isEmpty)

        await rig.manager.waitForStopCompletion()
        await rig.waitForPhase(.off)
        #expect(rig.manager.stops == [true])
        #expect(rig.controller.phase == .off)
    }

    @Test func aDeclinedConsentKeepsItsRecoveryState() async {
        let rig = Rig()
        rig.manager.installFailure = .permissionRequired
        await signedIn(rig)
        rig.controller.enable()
        await rig.controller.waitForPendingOperation()
        #expect(rig.controller.phase == .failed(.permissionRequired))

        // iOS reports the VPN as off right after the declined prompt; the
        // failure (and its retry) must stay on screen.
        rig.manager.report(.off)
        #expect(rig.controller.phase == .failed(.permissionRequired))
    }

    @Test func statusChangesFromSettingsAreMirrored() async {
        let rig = Rig()
        await signedIn(rig)
        rig.controller.enable()
        await rig.controller.waitForPendingOperation()

        rig.manager.report(.connected)
        #expect(rig.controller.phase == .connected)
        #expect(rig.controller.phase.isRequestedOn)
        rig.manager.report(.off)
        #expect(rig.controller.phase == .off)
        #expect(!rig.controller.phase.isRequestedOn)
    }

    @Test func disablingKeepsTheSavedVPN() async {
        let rig = Rig()
        await signedIn(rig)
        rig.controller.enable()
        await rig.controller.waitForPendingOperation()
        rig.controller.disable()
        #expect(rig.controller.phase == .disconnecting)
        await rig.controller.waitForPendingOperation()

        #expect(rig.manager.stops == [false])
        #expect(rig.controller.phase == .off)
    }

    @Test func signingOutRemovesTheVPN() async {
        let rig = Rig()
        await signedIn(rig)
        rig.controller.enable()
        await rig.controller.waitForPendingOperation()
        rig.controller.setScope(nil)
        await rig.controller.waitForPendingOperation()

        #expect(rig.manager.stops == [true])
        #expect(rig.controller.phase == .off)
    }

    @Test func signingOutRetriesCleanupAfterATransientRemovalFailure() async {
        let rig = Rig()
        await signedIn(rig)
        rig.manager.stopFailuresRemaining = 1
        rig.controller.setScope(nil)
        await rig.controller.waitForPendingOperation()

        #expect(rig.manager.stopAttempts == [true, true])
        #expect(rig.manager.stops == [true])
        #expect(rig.controller.phase == .off)
    }

    @Test func failedSignOutCleanupCanBeRetriedFromTheRecoveryAction() async {
        let rig = Rig(cleanupRetryCount: 1)
        await signedIn(rig)
        rig.manager.stopFailuresRemaining = 1

        rig.controller.setScope(nil)
        await rig.controller.waitForPendingOperation()
        #expect(rig.controller.phase == .failed(.configuration))

        rig.controller.retry()
        await rig.controller.waitForPendingOperation()

        #expect(rig.manager.stopAttempts == [true, true])
        #expect(rig.manager.stops == [true])
        #expect(rig.controller.phase == .off)
    }

    @Test func failedSignOutRevocationStillRemovesTheLocalVPN() async {
        let pendingStore = InMemoryCloudSystemVPNPendingRevocationStore()
        let rig = Rig(
            cleanupRetryCount: 1,
            pendingRevocationStore: pendingStore
        )
        await signedIn(rig)
        rig.controller.enable()
        await rig.controller.waitForPendingOperation()
        rig.service.revocationFailure = StubError(message: "offline")

        rig.controller.setScope(nil)
        await rig.controller.waitForPendingOperation()

        #expect(rig.manager.stops == [true])
        #expect(rig.controller.phase == .failed(.configuration))
        #expect(await pendingStore.load(scope: "user-1/team-1") == ["ios-abc"])
    }

    @Test func failedAccountSwitchCleanupCanBeRetriedFromTheRecoveryAction() async {
        let rig = Rig(cleanupRetryCount: 1)
        await signedIn(rig, scope: "user-1/team-1")
        rig.manager.stopFailuresRemaining = 1

        rig.controller.setScope("user-2/team-9")
        await rig.controller.waitForPendingOperation()
        #expect(rig.controller.phase == .failed(.configuration))

        rig.controller.retry()
        await rig.controller.waitForPendingOperation()

        #expect(rig.manager.stopAttempts == [true, true])
        #expect(rig.manager.stops == [true])
        #expect(rig.manager.refreshedScopes == ["user-1/team-1", "user-2/team-9"])
        #expect(rig.controller.phase == .off)
    }

    @Test func switchingAccountsRemovesTheOldAccountsVPNFirst() async {
        let rig = Rig()
        await signedIn(rig, scope: "user-1/team-1")
        rig.controller.setScope("user-2/team-9")
        await rig.controller.waitForPendingOperation()

        #expect(rig.manager.stops == [true])
        #expect(rig.manager.refreshedScopes == ["user-1/team-1", "user-2/team-9"])
    }

    @Test func switchingAccountsLoadsPendingRevocationsForTheKnownPreviousScope() async {
        let pendingStore = InMemoryCloudSystemVPNPendingRevocationStore()
        await pendingStore.save(["ios-abc"], scope: "user-1/team-1")
        let rig = Rig(pendingRevocationStore: pendingStore)
        rig.manager.isAvailable = false

        rig.controller.setScope("user-1/team-1")
        rig.manager.isAvailable = true
        rig.controller.setScope("user-2/team-9")
        await rig.controller.waitForPendingOperation()

        #expect(rig.service.calls.revoke.count == 1)
        #expect(rig.service.calls.revoke.first?.fingerprint == "ios-abc")
        #expect(await pendingStore.load(scope: "user-1/team-1").isEmpty)
        #expect(rig.manager.refreshedScopes == ["user-2/team-9"])
    }

    @Test func switchingAccountsRevokesTheOldBrowserPeer() async {
        let rig = Rig(credentials: {
            (accessToken: "old-access", refreshToken: "old-refresh")
        })
        await signedIn(rig, scope: "user-1/team-1")
        rig.controller.enable()
        await rig.controller.waitForPendingOperation()

        rig.controller.setScope("user-2/team-9")
        await rig.controller.waitForPendingOperation()

        #expect(rig.service.calls.revoke.count == 1)
        #expect(rig.service.calls.revoke.first?.fingerprint == "ios-abc")
        #expect(rig.service.calls.revoke.first?.purpose == .browser)
        #expect(rig.service.calls.revokeCredentials.count == 1)
        #expect(rig.service.calls.revokeCredentials.first?.accessToken == "old-access")
        #expect(rig.service.calls.revokeCredentials.first?.refreshToken == "old-refresh")
    }

    @Test func switchingAccountsPersistsTheOldBrowserPeerBeforeRevocation() async {
        let pendingStore = InMemoryCloudSystemVPNPendingRevocationStore()
        let rig = Rig(pendingRevocationStore: pendingStore)
        await signedIn(rig, scope: "user-1/team-1")
        rig.controller.enable()
        await rig.controller.waitForPendingOperation()

        rig.controller.setScope("user-2/team-9")
        await rig.service.waitForRevocation()

        #expect(await pendingStore.load(scope: "user-1/team-1") == ["ios-abc"])
        await rig.controller.waitForPendingOperation()
    }

    @Test func switchingAccountsPersistsTheOldBrowserPeerWhenVPNIsUnavailable() async {
        let pendingStore = InMemoryCloudSystemVPNPendingRevocationStore()
        let rig = Rig(pendingRevocationStore: pendingStore)
        await signedIn(rig, scope: "user-1/team-1")
        rig.controller.enable()
        await rig.controller.waitForPendingOperation()

        rig.manager.isAvailable = false
        rig.controller.setScope("user-2/team-9")
        await rig.controller.waitForPendingOperation()

        #expect(await pendingStore.load(scope: "user-1/team-1") == ["ios-abc"])
    }

    @Test func theFirstSignedInScopeDoesNotRemoveAnything() async {
        let rig = Rig()
        await signedIn(rig)
        #expect(rig.manager.stops.isEmpty)
        #expect(rig.manager.refreshedScopes == ["user-1/team-1"])
    }

    @Test func enablingWithoutAnAccountFailsWithoutCallingCloud() async {
        let rig = Rig()
        rig.controller.enable()
        await rig.controller.waitForPendingOperation()
        #expect(rig.service.calls.enroll.isEmpty)
        #expect(rig.controller.phase == .failed(.enrollment))
    }

    @Test func anUnavailableDeviceNeverEnrolls() async {
        let rig = Rig()
        rig.manager.isAvailable = false
        await signedIn(rig)
        #expect(!rig.controller.isAvailable)
        rig.controller.enable()
        await rig.controller.waitForPendingOperation()
        #expect(rig.service.calls.enroll.isEmpty)
        #expect(rig.controller.phase == .failed(.unavailable))
    }

    @Test func anUnavailableDeviceNeverTouchesVPNStorage() async {
        let rig = Rig()
        rig.manager.isAvailable = false
        rig.controller.setScope("user-1/team-1")
        rig.controller.setScope(nil)
        await rig.controller.refresh()
        await rig.controller.waitForPendingOperation()
        #expect(rig.manager.stops.isEmpty)
        #expect(rig.manager.refreshedScopes.isEmpty)
        #expect(rig.controller.phase == .off)
    }

    @Test func routePolicyAdmitsOnlyPrivateRanges() {
        let policy = CloudVPNRoutePolicy()
        #expect(policy.permits("10.0.0.0/8"))
        #expect(policy.permits("10.100.0.0/16"))
        #expect(policy.permits("172.16.0.0/12"))
        #expect(policy.permits("192.168.1.0/24"))
        #expect(policy.permits("100.64.0.7/32"))
        #expect(policy.permits("fd7a:7570:6c6b::/64"))
        #expect(policy.permits(" fd00::/8 "))

        #expect(!policy.permits("0.0.0.0/0"))
        #expect(!policy.permits("8.8.8.8/32"))
        #expect(!policy.permits("10.0.0.0/7"))
        #expect(!policy.permits("172.32.0.0/16"))
        #expect(!policy.permits("100.128.0.0/10"))
        #expect(!policy.permits("::/0"))
        #expect(!policy.permits("2600:1f18::1/128"))
        #expect(!policy.permits("10.0.0.1"))
        #expect(!policy.permits("10.0.0.0/33"))
        #expect(!policy.permits("not-an-address/8"))
    }

    @Test func routePolicyRejectsDNSDirectives() {
        let policy = CloudVPNRoutePolicy()
        let config = Fixtures.serverConfig + "\nDNS = 1.1.1.1\n"
        #expect(!policy.permitsOnlyPrivateRoutes(inQuickConfig: config))
    }
}
