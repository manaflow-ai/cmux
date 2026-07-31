import CmuxAuthRuntime
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
}
