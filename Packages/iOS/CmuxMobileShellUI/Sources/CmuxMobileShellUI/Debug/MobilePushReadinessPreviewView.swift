#if os(iOS) && DEBUG
import CmuxAuthRuntime
import CmuxMobileRPC
import CmuxMobileSupport
import SwiftUI

/// Deterministic production-settings harness for XCUITest.
///
/// It mounts the same ``MobilePushSettingsContent`` used by Settings. Only the
/// network/OS seams are fixtures, so accessibility, localization, optimistic
/// mutation, rollback, and every rendered repair action remain production code.
struct MobilePushReadinessPreviewView: View {
    private let fixture: Fixture
    private let rejectsMacMutations: Bool
    private let delaysPhoneMutation: Bool

    @State private var phoneEnabled: Bool
    @State private var authorization: MobilePushAuthorization
    @State private var registration: PushRegistrationSnapshot
    @State private var macStatus: MobileHostPhonePushStatus?
    @State private var pendingPhoneMutation: Bool?

    init(state: String, environment: [String: String] = ProcessInfo.processInfo.environment) {
        let fixture = Fixture(rawValue: state) ?? .healthy
        self.fixture = fixture
        self.rejectsMacMutations = environment["CMUX_UITEST_PUSH_MUTATION_FAILURE"] == "1"
        self.delaysPhoneMutation = environment["CMUX_UITEST_PUSH_PHONE_MUTATION_DELAY"] == "1"
        self._phoneEnabled = State(initialValue: fixture.registration.isEnabled)
        self._authorization = State(initialValue: fixture.authorization)
        self._registration = State(initialValue: fixture.registration)
        self._macStatus = State(initialValue: fixture.macStatus)
        self._pendingPhoneMutation = State(initialValue: nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.string(
                    "mobile.settings.notifications",
                    defaultValue: "Push Alerts"
                )) {
                    if delaysPhoneMutation {
                        MobilePushToggle(
                            isEnabled: $phoneEnabled,
                            applyEnabledIntent: queuePhoneEnabled
                        )
                    } else {
                        MobilePushSettingsContent(
                            readiness: readiness,
                            phoneEnabled: $phoneEnabled,
                            macStatus: macStatus,
                            supportsMacSettings: macStatus != nil,
                            supportsMacTest: macStatus != nil,
                            canConnectMac: true,
                            onPhoneEnabledChange: setPhoneEnabled,
                            onRepair: repair,
                            onMacMutation: mutateMac,
                            onSendTest: { .queuedOnMac }
                        )
                    }

                    if let pendingPhoneMutation {
                        Button {
                            completePhoneMutation()
                        } label: {
                            Text(L10n.string(
                                "mobile.settings.done",
                                defaultValue: "Done"
                            ))
                        }
                        .accessibilityIdentifier(
                            "MobilePushReadinessCompletePhoneMutation-"
                                + (pendingPhoneMutation ? "on" : "off")
                        )
                    }
                }
            }
            .navigationTitle(L10n.string(
                "mobile.workspaces.settings",
                defaultValue: "Settings"
            ))
        }
        .accessibilityIdentifier("MobilePushReadinessPreview")
    }

    private var readiness: MobilePushReadiness {
        MobilePushReadiness.resolve(
            authorization: authorization,
            registration: registration,
            mac: macStatus.map(MobilePushReadiness.MacStatus.init),
            systemSettings: .authorizationOnly(authorization),
            phoneAPIOrigin: Self.apiOrigin
        )
    }

    @MainActor
    private func setPhoneEnabled(_ enabled: Bool) async -> Bool {
        applyPhoneMutation(enabled)
        return enabled
    }

    @MainActor
    private func queuePhoneEnabled(_ enabled: Bool) {
        pendingPhoneMutation = enabled
    }

    @MainActor
    private func completePhoneMutation() {
        guard let pendingPhoneMutation else { return }
        self.pendingPhoneMutation = nil
        applyPhoneMutation(pendingPhoneMutation)
    }

    @MainActor
    private func applyPhoneMutation(_ enabled: Bool) {
        phoneEnabled = enabled
        registration = enabled
            ? Self.registered
            : .disabled
    }

    @MainActor
    private func repair(_ repair: MobilePushReadiness.Repair) async -> Bool {
        switch repair {
        case .enableOnPhone:
            return await setPhoneEnabled(true)
        case .retryDeviceTokenRegistration, .retryRegistration:
            registration = Self.registered
            return true
        case .connectMac:
            macStatus = Self.healthyMac
            return true
        case .enableOnMac:
            return await mutateMac(.forwardingEnabled(true))
        case .leaveMacOrUseAlwaysMode:
            return await mutateMac(.mode(.always))
        case .openSystemSettings, .signInAgain, .finishAccountDeletion,
             .disablePushOnAnotherDevice, .signIntoMatchingAccount,
             .rebuildMatchingApps, .waitForDeviceToken:
            return true
        }
    }

    @MainActor
    private func mutateMac(_ mutation: MobilePushMacMutation) async -> Bool {
        guard !rejectsMacMutations, let current = macStatus else {
            return false
        }
        let forwardingEnabled: Bool
        let mode: MobileHostPhonePushStatus.Mode
        let hideContent: Bool
        switch mutation {
        case let .forwardingEnabled(value):
            forwardingEnabled = value
            mode = current.mode
            hideContent = current.hideContent
        case let .mode(value):
            forwardingEnabled = current.forwardingEnabled
            mode = value
            hideContent = current.hideContent
        case let .hideContent(value):
            forwardingEnabled = current.forwardingEnabled
            mode = current.mode
            hideContent = value
        }
        macStatus = MobileHostPhonePushStatus(
            forwardingEnabled: forwardingEnabled,
            mode: mode,
            admission: forwardingEnabled ? .allowed : .forwardingDisabled,
            queuePersistence: current.queuePersistence,
            hideContent: hideContent,
            apiOrigin: current.apiOrigin,
            accountScope: current.accountScope
        )
        return true
    }

    private enum Fixture: String {
        case healthy
        case osDenied = "os_denied"
        case backendRetry = "backend_retry"
        case macForwardingOff = "mac_forwarding_off"
        case macUnavailable = "mac_unavailable"
        case limitedProvisional = "limited_provisional"

        var authorization: MobilePushAuthorization {
            switch self {
            case .osDenied: .denied
            case .limitedProvisional: .provisional
            case .healthy, .backendRetry, .macForwardingOff, .macUnavailable:
                .authorized
            }
        }

        var registration: PushRegistrationSnapshot {
            switch self {
            case .backendRetry:
                PushRegistrationSnapshot(
                    isEnabled: true,
                    hasDeviceToken: true,
                    backendState: .failed(.serviceUnavailable)
                )
            case .healthy, .osDenied, .macForwardingOff, .macUnavailable,
                 .limitedProvisional:
                MobilePushReadinessPreviewView.registered
            }
        }

        var macStatus: MobileHostPhonePushStatus? {
            switch self {
            case .macUnavailable:
                nil
            case .macForwardingOff:
                MobileHostPhonePushStatus(
                    forwardingEnabled: false,
                    mode: .onlyWhenAway,
                    admission: .forwardingDisabled,
                    queuePersistence: .healthy,
                    apiOrigin: MobilePushReadinessPreviewView.apiOrigin,
                    accountScope: .verifiedSameAccount
                )
            case .healthy, .osDenied, .backendRetry, .limitedProvisional:
                MobilePushReadinessPreviewView.healthyMac
            }
        }
    }

    private static let apiOrigin = "https://cmux.com"
    private static let registered = PushRegistrationSnapshot(
        isEnabled: true,
        hasDeviceToken: true,
        backendState: .registered
    )
    private static let healthyMac = MobileHostPhonePushStatus(
        forwardingEnabled: true,
        mode: .onlyWhenAway,
        admission: .allowed,
        queuePersistence: .healthy,
        apiOrigin: apiOrigin,
        accountScope: .verifiedSameAccount
    )
}
#endif
