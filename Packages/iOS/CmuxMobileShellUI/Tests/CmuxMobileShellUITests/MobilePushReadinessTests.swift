import CmuxAuthRuntime
import CmuxMobileRPC
import Testing

@testable import CmuxMobileShellUI

@Suite struct MobilePushReadinessTests {
    private let registered = PushRegistrationSnapshot(
        isEnabled: true,
        hasDeviceToken: true,
        backendState: .registered
    )

    @Test func localOptInAloneIsNeverReportedAsReady() {
        let readiness = MobilePushReadiness.resolve(
            authorization: .authorized,
            registration: PushRegistrationSnapshot(
                isEnabled: true,
                hasDeviceToken: false,
                backendState: .awaitingDeviceToken
            ),
            mac: nil,
            phoneAPIOrigin: "https://cmux.com"
        )

        #expect(readiness == .blocked(.awaitingDeviceToken))
    }

    @Test func connectMacRepairRequiresTheManualPairingCapability() {
        #expect(
            MobilePushSettingsContent.shouldPresentRepair(
                .connectMac,
                canConnectMac: false
            ) == false
        )
        #expect(
            MobilePushSettingsContent.shouldPresentRepair(
                .connectMac,
                canConnectMac: true
            )
        )
        #expect(
            MobilePushSettingsContent.shouldPresentRepair(
                .enableOnPhone,
                canConnectMac: false
            )
        )
    }

    @Test func cachedTokenAwaitingBackendAcknowledgementOffersRetry() {
        let readiness = MobilePushReadiness.resolve(
            authorization: .authorized,
            registration: PushRegistrationSnapshot(
                isEnabled: true,
                hasDeviceToken: true,
                backendState: .registrationRequired
            ),
            mac: nil,
            phoneAPIOrigin: "https://cmux.com"
        )

        #expect(readiness == .blocked(.backendRegistrationRequired))
        #expect(readiness.repair == .retryRegistration)
    }

    @Test func liveSystemDenialOverridesPersistedOptIn() {
        let readiness = MobilePushReadiness.resolve(
            authorization: .denied,
            registration: registered,
            mac: .init(
                forwardingEnabled: true,
                mode: .always,
                apiOrigin: "https://cmux.com",
                accountVerified: true
            ),
            phoneAPIOrigin: "https://cmux.com"
        )

        #expect(readiness == .blocked(.systemPermissionDenied))
        #expect(readiness.repair == .openSystemSettings)
    }

    @Test(arguments: [
        MobilePushAuthorization.denied,
        .unsupported,
    ])
    func terminalOSStateOverridesLocalOptOut(
        authorization: MobilePushAuthorization
    ) {
        let readiness = MobilePushReadiness.resolve(
            authorization: authorization,
            registration: .disabled,
            mac: nil,
            phoneAPIOrigin: "https://cmux.com"
        )

        #expect(
            readiness == .blocked(
                authorization == .denied
                    ? .systemPermissionDenied
                    : .systemNotificationsUnsupported
            )
        )
        #expect(readiness.repair == .openSystemSettings)
    }

    @Test func undeterminedOSStateWithLocalOptOutStillOffersEnable() {
        let readiness = MobilePushReadiness.resolve(
            authorization: .notDetermined,
            registration: .disabled,
            mac: nil,
            phoneAPIOrigin: "https://cmux.com"
        )

        #expect(readiness == .blocked(.phoneOptInDisabled))
        #expect(readiness.repair == .enableOnPhone)
    }

    @Test func registeredPhoneWithoutAttachedMacReportsMacUnavailable() {
        let readiness = MobilePushReadiness.resolve(
            authorization: .authorized,
            registration: registered,
            mac: nil,
            phoneAPIOrigin: "https://cmux.com"
        )

        #expect(readiness == .blocked(.macStatusUnavailable))
        #expect(readiness.repair == .connectMac)
    }

    @Test func failedAPNsTokenCallbackHasItsOwnRetryAction() {
        let readiness = MobilePushReadiness.resolve(
            authorization: .authorized,
            registration: PushRegistrationSnapshot(
                isEnabled: true,
                hasDeviceToken: false,
                backendState: .deviceTokenRegistrationFailed
            ),
            mac: nil,
            phoneAPIOrigin: "https://cmux.com"
        )

        #expect(readiness == .blocked(.deviceTokenRegistrationFailed))
        #expect(readiness.repair == .retryDeviceTokenRegistration)
    }

    @Test func backendDeviceCeilingNamesTheLimitAndItsOnlySafeRepair() {
        let readiness = MobilePushReadiness.resolve(
            authorization: .authorized,
            registration: PushRegistrationSnapshot(
                isEnabled: true,
                hasDeviceToken: true,
                backendState: .failed(.deviceLimitReached(limit: 200))
            ),
            mac: nil,
            phoneAPIOrigin: "https://cmux.com"
        )

        #expect(readiness == .blocked(.deviceLimitReached(limit: 200)))
        #expect(readiness.repair == .disablePushOnAnotherDevice)
    }

    @Test(arguments: [
        MobilePushAuthorization.provisional,
        .ephemeral,
    ])
    func quietOrTemporaryOSAuthorizationDoesNotMasqueradeAsFullReadiness(
        authorization: MobilePushAuthorization
    ) {
        let readiness = MobilePushReadiness.resolve(
            authorization: authorization,
            registration: registered,
            mac: .init(
                forwardingEnabled: true,
                mode: .always,
                apiOrigin: "https://cmux.com",
                accountVerified: true
            ),
            phoneAPIOrigin: "https://cmux.com"
        )

        #expect(readiness == .limited(mode: .always, authorization: authorization))
        #expect(readiness.repair == .openSystemSettings)
    }

    @Test(arguments: MobilePushPresentationLimitation.allCases.filter {
        $0 != .scheduledDeliveryEnabled
    })
    func eachSystemPresentationPolicyIsReportedIndividually(
        limitation: MobilePushPresentationLimitation
    ) {
        let settings = MobilePushSystemSettings(
            authorization: .authorized,
            alertsEnabled: limitation != .alertsDisabled,
            soundsEnabled: limitation != .soundsDisabled,
            badgesEnabled: limitation != .badgesDisabled,
            lockScreenEnabled: limitation != .lockScreenDisabled,
            notificationCenterEnabled:
                limitation != .notificationCenterDisabled,
            timeSensitiveEnabled: limitation != .timeSensitiveDisabled,
            scheduledDeliveryEnabled: false
        )
        let readiness = MobilePushReadiness.resolve(
            authorization: .authorized,
            registration: registered,
            mac: .init(
                forwardingEnabled: true,
                mode: .always,
                apiOrigin: "https://cmux.com",
                accountVerified: true
            ),
            systemSettings: settings,
            phoneAPIOrigin: "https://cmux.com"
        )

        #expect(
            readiness == .presentationLimited(
                mode: .always,
                limitations: [limitation]
            )
        )
        #expect(readiness.repair == .openSystemSettings)
    }

    @Test func scheduledDeliveryIsAWarningWhenTimeSensitiveIsDisabled() {
        let settings = MobilePushSystemSettings(
            authorization: .authorized,
            alertsEnabled: true,
            soundsEnabled: true,
            badgesEnabled: true,
            lockScreenEnabled: true,
            notificationCenterEnabled: true,
            timeSensitiveEnabled: false,
            scheduledDeliveryEnabled: true
        )
        let readiness = MobilePushReadiness.resolve(
            authorization: .authorized,
            registration: registered,
            mac: .init(
                forwardingEnabled: true,
                mode: .always,
                apiOrigin: "https://cmux.com",
                accountVerified: true
            ),
            systemSettings: settings,
            phoneAPIOrigin: "https://cmux.com"
        )

        #expect(
            readiness == .presentationLimited(
                mode: .always,
                limitations: [.timeSensitiveDisabled, .scheduledDeliveryEnabled]
            )
        )
    }

    @Test func timeSensitiveDeliveryBypassesScheduledSummary() {
        let settings = MobilePushSystemSettings(
            authorization: .authorized,
            alertsEnabled: true,
            soundsEnabled: true,
            badgesEnabled: true,
            lockScreenEnabled: true,
            notificationCenterEnabled: true,
            timeSensitiveEnabled: true,
            scheduledDeliveryEnabled: true
        )
        let readiness = MobilePushReadiness.resolve(
            authorization: .authorized,
            registration: registered,
            mac: .init(
                forwardingEnabled: true,
                mode: .always,
                apiOrigin: "https://cmux.com",
                accountVerified: true
            ),
            systemSettings: settings,
            phoneAPIOrigin: "https://cmux.com"
        )

        #expect(readiness == .ready(mode: .always))
    }

    @Test(arguments: [
        MobileHostPhonePushStatus.QueuePersistence.loadFailed,
        .saveFailed,
        .clearFailed,
    ])
    func retryQueuePersistenceFailuresDegradeRatherThanClaimFullReadiness(
        queuePersistence: MobileHostPhonePushStatus.QueuePersistence
    ) {
        let readiness = MobilePushReadiness.resolve(
            authorization: .authorized,
            registration: registered,
            mac: .init(
                forwardingEnabled: true,
                mode: .always,
                admission: .allowed,
                queuePersistence: queuePersistence,
                apiOrigin: "https://cmux.com",
                accountVerified: true
            ),
            phoneAPIOrigin: "https://cmux.com"
        )

        #expect(
            readiness == .reliabilityLimited(
                mode: .always,
                queuePersistence: queuePersistence
            )
        )
        #expect(readiness.repair == nil)
    }

    @Test func uninitializedRetryQueueIsReportedAsUnconfirmed() {
        let readiness = MobilePushReadiness.resolve(
            authorization: .authorized,
            registration: registered,
            mac: .init(
                forwardingEnabled: true,
                mode: .always,
                admission: .allowed,
                queuePersistence: .unknown,
                apiOrigin: "https://cmux.com",
                accountVerified: true
            ),
            phoneAPIOrigin: "https://cmux.com"
        )

        #expect(
            readiness == .reliabilityLimited(
                mode: .always,
                queuePersistence: .unknown
            )
        )
    }

    @Test func unknownAdmissionFailsClosedInsteadOfReportingReady() {
        let readiness = MobilePushReadiness.resolve(
            authorization: .authorized,
            registration: registered,
            mac: .init(
                forwardingEnabled: true,
                mode: .always,
                admission: .unknown,
                apiOrigin: "https://cmux.com",
                accountVerified: true
            ),
            phoneAPIOrigin: "https://cmux.com"
        )

        #expect(readiness == .blocked(.macAdmissionUnavailable))
        #expect(readiness.repair == .connectMac)
    }

    @Test func authenticatedConnectionAccountMismatchIsDistinctFromUnavailableMac() {
        let readiness = MobilePushReadiness.resolve(
            authorization: .authorized,
            registration: registered,
            mac: nil,
            macAccountMismatch: true,
            phoneAPIOrigin: "https://cmux.com"
        )

        #expect(readiness == .blocked(.macAccountMismatch))
        #expect(readiness.repair == .signIntoMatchingAccount)
    }

    @Test func attachedMacWithForwardingOffReportsTheSecondGate() {
        let readiness = MobilePushReadiness.resolve(
            authorization: .authorized,
            registration: registered,
            mac: .init(
                forwardingEnabled: false,
                mode: .onlyWhenAway,
                apiOrigin: "https://cmux.com",
                accountVerified: true
            ),
            phoneAPIOrigin: "https://cmux.com"
        )

        #expect(readiness == .blocked(.macForwardingDisabled))
        #expect(readiness.repair == .enableOnMac)
    }

    @Test func mismatchedAPIOriginsCannotReportReady() {
        let readiness = MobilePushReadiness.resolve(
            authorization: .authorized,
            registration: registered,
            mac: .init(
                forwardingEnabled: true,
                mode: .always,
                apiOrigin: "http://localhost:4381",
                accountVerified: true
            ),
            phoneAPIOrigin: "https://cmux-staging.vercel.app"
        )

        #expect(readiness == .blocked(.apiOriginMismatch))
        #expect(readiness.repair == .rebuildMatchingApps)
    }

    @Test(arguments: [
        "ws://cmux.example",
        "wss://cmux.example",
        "file:///tmp/cmux",
        "relative/cmux",
    ])
    func nonHTTPAPIOriginsFailClosedEvenWhenBothSidesMatch(
        origin: String
    ) {
        let readiness = MobilePushReadiness.resolve(
            authorization: .authorized,
            registration: registered,
            mac: .init(
                forwardingEnabled: true,
                mode: .always,
                apiOrigin: origin,
                accountVerified: true
            ),
            phoneAPIOrigin: origin
        )

        #expect(readiness == .blocked(.apiOriginMismatch))
        #expect(readiness.repair == .rebuildMatchingApps)
    }

    @Test func everyGateMustPassBeforeReadyIncludesTheLiveMode() {
        let readiness = MobilePushReadiness.resolve(
            authorization: .authorized,
            registration: registered,
            mac: .init(
                forwardingEnabled: true,
                mode: .onlyWhenAway,
                apiOrigin: "https://cmux.com/",
                accountVerified: true
            ),
            phoneAPIOrigin: "https://cmux.com"
        )

        #expect(readiness == .ready(mode: .onlyWhenAway))
    }

    @Test func activeMacInOnlyWhenAwayModeNeverReportsReady() {
        let readiness = MobilePushReadiness.resolve(
            authorization: .authorized,
            registration: registered,
            mac: .init(
                forwardingEnabled: true,
                mode: .onlyWhenAway,
                admission: .suppressedMacActive,
                apiOrigin: "https://cmux.com",
                accountVerified: true
            ),
            phoneAPIOrigin: "https://cmux.com"
        )

        #expect(readiness == .blocked(.macCurrentlyActive))
        #expect(readiness.repair == .leaveMacOrUseAlwaysMode)
    }
}
