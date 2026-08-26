#if os(iOS)
import CmuxAuthRuntime
import CmuxMobileRPC
import CmuxMobileShell
import CmuxMobileSupport
import SwiftUI

enum MobilePushMacMutation: Equatable, Sendable {
    case forwardingEnabled(Bool)
    case mode(MobileHostPhonePushStatus.Mode)
    case hideContent(Bool)
}

/// The production Push Alerts settings surface.
///
/// Its status is computed from the full readiness pipeline, while Mac-owned
/// privacy controls are optimistic only until the authenticated Mac confirms
/// the mutation. A failed mutation rolls every control back to the last
/// authoritative status instead of leaving a misleading local value behind.
struct MobilePushSettingsContent: View {
    let readiness: MobilePushReadiness
    @Binding var phoneEnabled: Bool
    let macStatus: MobileHostPhonePushStatus?
    let supportsMacSettings: Bool
    let supportsMacTest: Bool
    let canConnectMac: Bool
    let onPhoneEnabledChange: @MainActor (Bool) async -> Bool
    let onRepair: @MainActor (MobilePushReadiness.Repair) async -> Bool
    let onMacMutation: @MainActor (MobilePushMacMutation) async -> Bool
    let onSendTest: @MainActor () async -> MobilePhonePushTestStage

    @State private var macForwardingEnabled: Bool
    @State private var macMode: MobileHostPhonePushStatus.Mode
    @State private var macHideContent: Bool
    @State private var confirmedMacStatus: MobileHostPhonePushStatus?
    @State private var isMutatingPhone = false
    @State private var isMutatingMac = false
    @State private var mutationFailed = false
    @State private var testStage: MobilePhonePushTestStage?
    @State private var isSendingTest = false

    init(
        readiness: MobilePushReadiness,
        phoneEnabled: Binding<Bool>,
        macStatus: MobileHostPhonePushStatus?,
        supportsMacSettings: Bool,
        supportsMacTest: Bool,
        canConnectMac: Bool,
        onPhoneEnabledChange: @escaping @MainActor (Bool) async -> Bool,
        onRepair: @escaping @MainActor (MobilePushReadiness.Repair) async -> Bool,
        onMacMutation: @escaping @MainActor (MobilePushMacMutation) async -> Bool,
        onSendTest: @escaping @MainActor () async -> MobilePhonePushTestStage
    ) {
        self.readiness = readiness
        self._phoneEnabled = phoneEnabled
        self.macStatus = macStatus
        self.supportsMacSettings = supportsMacSettings
        self.supportsMacTest = supportsMacTest
        self.canConnectMac = canConnectMac
        self.onPhoneEnabledChange = onPhoneEnabledChange
        self.onRepair = onRepair
        self.onMacMutation = onMacMutation
        self.onSendTest = onSendTest
        self._macForwardingEnabled = State(
            initialValue: macStatus?.forwardingEnabled ?? false
        )
        self._macMode = State(initialValue: macStatus?.mode ?? .onlyWhenAway)
        self._macHideContent = State(
            initialValue: macStatus?.hideContent ?? false
        )
        self._confirmedMacStatus = State(initialValue: macStatus)
    }

    var body: some View {
        Group {
            statusRow

            Toggle(
                L10n.string(
                    "mobile.notifications.phoneEnabled",
                    defaultValue: "Allow Push Alerts on This iPhone"
                ),
                isOn: phoneEnabledBinding
            )
            .accessibilityIdentifier("MobileSettingsNotifications")
            .disabled(isMutatingPhone)

            if let repair = readiness.repair,
               Self.shouldPresentRepair(repair, canConnectMac: canConnectMac),
               let repairPresentation = repairPresentation(for: repair) {
                Button {
                    guard !isMutatingPhone else { return }
                    isMutatingPhone = true
                    Task {
                        defer { isMutatingPhone = false }
                        let succeeded = await onRepair(repair)
                        if repair == .enableOnPhone {
                            phoneEnabled = succeeded
                        }
                    }
                } label: {
                    Label(
                        repairPresentation.title,
                        systemImage: repairPresentation.systemImage
                    )
                }
                .accessibilityIdentifier(repairPresentation.identifier)
                .disabled(isMutatingPhone || isMutatingMac)
            }

            if let macStatus {
            Toggle(
                L10n.string(
                    "mobile.notifications.macForwarding",
                    defaultValue: "Forward Alerts from This Mac"
                ),
                isOn: macForwardingBinding
            )
            .accessibilityIdentifier("MobileSettingsPushMacForwardingToggle")
            .disabled(!supportsMacSettings || isMutatingMac)

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.string(
                    "mobile.notifications.macMode",
                    defaultValue: "Forwarding Mode"
                ))
                .font(.subheadline)

                HStack(spacing: 8) {
                    modeButton(
                        .onlyWhenAway,
                        title: L10n.string(
                            "mobile.notifications.mode.onlyWhenAway",
                            defaultValue: "Only When Away"
                        ),
                        identifier: "MobileSettingsPushModeOnlyWhenAway"
                    )
                    modeButton(
                        .always,
                        title: L10n.string(
                            "mobile.notifications.mode.always",
                            defaultValue: "Always"
                        ),
                        identifier: "MobileSettingsPushModeAlways"
                    )
                }
            }

            Toggle(
                L10n.string(
                    "mobile.notifications.hideContent",
                    defaultValue: "Hide Notification Content"
                ),
                isOn: macHideContentBinding
            )
            .accessibilityIdentifier("MobileSettingsPushHideContentToggle")
            .disabled(!supportsMacSettings || isMutatingMac)

            if !supportsMacSettings {
                Text(L10n.string(
                    "mobile.notifications.macUpdateRequired",
                    defaultValue: "Update cmux on this Mac to change forwarding from iPhone."
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            if mutationFailed {
                Text(L10n.string(
                    "mobile.notifications.macMutationFailed",
                    defaultValue: "The Mac did not save that change. Its last confirmed settings were restored."
                ))
                .font(.footnote)
                .foregroundStyle(.red)
                .accessibilityIdentifier("MobileSettingsPushMutationError")
            }

            if macStatus.mode == .onlyWhenAway {
                Text(L10n.string(
                    "mobile.notifications.awayExplanation",
                    defaultValue: "Only When Away sends after the Mac is locked, asleep, or inactive."
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Button {
                isSendingTest = true
                testStage = nil
                Task {
                    testStage = await onSendTest()
                    isSendingTest = false
                }
            } label: {
                Label(
                    L10n.string(
                        "mobile.notifications.test.send",
                        defaultValue: "Send Test Alert"
                    ),
                    systemImage: "paperplane"
                )
            }
            .disabled(!supportsMacTest || isSendingTest || isMutatingMac)
            .accessibilityIdentifier("MobileSettingsPushSendTest")

                if let testStage {
                    Text(testStageText(testStage))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("MobileSettingsPushTestResult")
                }
            }
        }
        .onChange(of: macStatus) { _, confirmed in
            confirmedMacStatus = confirmed
            guard let confirmed else { return }
            macForwardingEnabled = confirmed.forwardingEnabled
            macMode = confirmed.mode
            macHideContent = confirmed.hideContent
            mutationFailed = false
        }
    }

    static func shouldPresentRepair(
        _ repair: MobilePushReadiness.Repair,
        canConnectMac: Bool
    ) -> Bool {
        repair != .connectMac || canConnectMac
    }

    private var statusRow: some View {
        HStack(spacing: 10) {
            Image(systemName: readinessSymbol)
                .foregroundStyle(readinessTint)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.string(
                    "mobile.notifications.readiness",
                    defaultValue: "Delivery Status"
                ))
                .font(.subheadline.weight(.semibold))
                Text(readinessText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(readinessText)
        .accessibilityIdentifier("MobileSettingsPushReadinessStatus")
    }

    private var phoneEnabledBinding: Binding<Bool> {
        Binding(
            get: { phoneEnabled },
            set: { requested in
                guard !isMutatingPhone else { return }
                let confirmed = phoneEnabled
                phoneEnabled = requested
                isMutatingPhone = true
                Task {
                    let succeeded = await onPhoneEnabledChange(requested)
                    if !succeeded {
                        phoneEnabled = confirmed
                    }
                    isMutatingPhone = false
                }
            }
        )
    }

    private var macForwardingBinding: Binding<Bool> {
        Binding(
            get: { macForwardingEnabled },
            set: { requested in
                guard !isMutatingMac else { return }
                macForwardingEnabled = requested
                performMacMutation(.forwardingEnabled(requested))
            }
        )
    }

    private var macHideContentBinding: Binding<Bool> {
        Binding(
            get: { macHideContent },
            set: { requested in
                guard !isMutatingMac else { return }
                macHideContent = requested
                performMacMutation(.hideContent(requested))
            }
        )
    }

    private func modeButton(
        _ mode: MobileHostPhonePushStatus.Mode,
        title: String,
        identifier: String
    ) -> some View {
        Button {
            guard !isMutatingMac, macMode != mode else { return }
            macMode = mode
            performMacMutation(.mode(mode))
        } label: {
            HStack(spacing: 5) {
                Image(systemName: macMode == mode ? "checkmark.circle.fill" : "circle")
                Text(title)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(!supportsMacSettings || isMutatingMac)
        .accessibilityIdentifier(identifier)
        .accessibilityValue(
            macMode == mode
                ? L10n.string(
                    "mobile.accessibility.selected",
                    defaultValue: "selected"
                )
                : L10n.string(
                    "mobile.accessibility.notSelected",
                    defaultValue: "not selected"
                )
        )
    }

    private func performMacMutation(_ mutation: MobilePushMacMutation) {
        mutationFailed = false
        isMutatingMac = true
        Task {
            let succeeded = await onMacMutation(mutation)
            isMutatingMac = false
            if !succeeded {
                if let confirmedMacStatus {
                    macForwardingEnabled = confirmedMacStatus.forwardingEnabled
                    macMode = confirmedMacStatus.mode
                    macHideContent = confirmedMacStatus.hideContent
                }
                mutationFailed = true
            }
        }
    }

}

private extension MobilePushSettingsContent {

    private var readinessText: String {
        switch readiness {
        case let .ready(mode):
            switch mode {
            case .onlyWhenAway:
                return L10n.string(
                    "mobile.notifications.status.readyAway",
                    defaultValue: "Ready, Only When Away"
                )
            case .always:
                return L10n.string(
                    "mobile.notifications.status.readyAlways",
                    defaultValue: "Ready, Always"
                )
            }
        case .limited:
            return L10n.string(
                "mobile.notifications.status.limitedAuthorization",
                defaultValue: "Limited, Delivered Quietly"
            )
        case .presentationLimited:
            return L10n.string(
                "mobile.notifications.status.presentationLimited",
                defaultValue: "Limited, Check iOS Presentation Settings"
            )
        case let .reliabilityLimited(_, queuePersistence):
            switch queuePersistence {
            case .unknown:
                return L10n.string(
                    "mobile.notifications.status.queueUnconfirmed",
                    defaultValue: "Limited, Delivery Recovery Unconfirmed"
                )
            case .loadFailed, .saveFailed, .clearFailed:
                return L10n.string(
                    "mobile.notifications.status.queueFailed",
                    defaultValue: "Limited, Delivery Recovery Unavailable"
                )
            case .healthy:
                return L10n.string(
                    "mobile.notifications.status.readyAlways",
                    defaultValue: "Ready, Always"
                )
            }
        case let .blocked(blocker):
            return blockedText(blocker)
        }
    }

    func blockedText(_ blocker: MobilePushReadiness.Blocker) -> String {
        switch blocker {
        case .phoneOptInDisabled, .systemPermissionNotRequested,
             .systemPermissionDenied, .systemNotificationsUnsupported,
             .awaitingDeviceToken, .deviceTokenRegistrationFailed:
            phoneBlockerText(blocker)
        case .registeringDevice, .backendRegistrationRequired,
             .authenticationRequired, .accountDeletionInProgress,
             .registrationRateLimited, .deviceLimitReached,
             .networkUnavailable, .pushServiceUnavailable,
             .invalidServerResponse, .registrationRejected,
             .invalidConfiguration:
            registrationBlockerText(blocker)
        case .macStatusUnavailable, .macAdmissionUnavailable,
             .macAccountMismatch, .macForwardingDisabled,
             .macCurrentlyActive, .apiOriginMismatch:
            macBlockerText(blocker)
        }
    }

    func phoneBlockerText(_ blocker: MobilePushReadiness.Blocker) -> String {
        switch blocker {
        case .phoneOptInDisabled:
            return L10n.string(
                "mobile.notifications.status.phoneOff",
                defaultValue: "Blocked, Off on This iPhone"
            )
        case .systemPermissionNotRequested:
            return L10n.string(
                "mobile.notifications.status.permissionNotRequested",
                defaultValue: "Blocked, iOS Permission Not Requested"
            )
        case .systemPermissionDenied:
            return L10n.string(
                "mobile.notifications.status.permissionDenied",
                defaultValue: "Blocked, iOS Permission Denied"
            )
        case .systemNotificationsUnsupported:
            return L10n.string(
                "mobile.notifications.status.unsupported",
                defaultValue: "Blocked, Notifications Unsupported"
            )
        case .awaitingDeviceToken:
            return L10n.string(
                "mobile.notifications.status.awaitingToken",
                defaultValue: "Blocked, Waiting for Notification Setup"
            )
        case .deviceTokenRegistrationFailed:
            return L10n.string(
                "mobile.notifications.status.tokenFailed",
                defaultValue: "Blocked, Notification Setup Failed"
            )
        default:
            assertionFailure("Expected a phone-side push blocker")
            return ""
        }
    }

    func registrationBlockerText(
        _ blocker: MobilePushReadiness.Blocker
    ) -> String {
        switch blocker {
        case .registeringDevice:
            return L10n.string(
                "mobile.notifications.status.registering",
                defaultValue: "Blocked, Registering This Device"
            )
        case .backendRegistrationRequired:
            return L10n.string(
                "mobile.notifications.status.backendRequired",
                defaultValue: "Blocked, Finishing Notification Setup"
            )
        case .authenticationRequired:
            return L10n.string(
                "mobile.notifications.status.authenticationRequired",
                defaultValue: "Blocked, Sign In Again"
            )
        case .accountDeletionInProgress:
            return L10n.string(
                "mobile.notifications.status.accountDeletion",
                defaultValue: "Blocked, Account Deletion in Progress"
            )
        case .registrationRateLimited:
            return L10n.string(
                "mobile.notifications.status.rateLimited",
                defaultValue: "Blocked, Registration Rate Limited"
            )
        case let .deviceLimitReached(limit):
            return String.localizedStringWithFormat(
                L10n.string(
                    "mobile.notifications.status.deviceLimitFormat",
                    defaultValue: "Blocked, %d-Device Limit Reached"
                ),
                limit
            )
        case .networkUnavailable:
            return L10n.string(
                "mobile.notifications.status.offline",
                defaultValue: "Blocked, Network Unavailable"
            )
        case .pushServiceUnavailable, .invalidServerResponse,
             .registrationRejected:
            return L10n.string(
                "mobile.notifications.status.registrationFailed",
                defaultValue: "Blocked, Registration Failed"
            )
        case .invalidConfiguration:
            return L10n.string(
                "mobile.notifications.status.invalidConfiguration",
                defaultValue: "Blocked, Invalid Push Configuration"
            )
        default:
            assertionFailure("Expected a registration push blocker")
            return ""
        }
    }

    func macBlockerText(_ blocker: MobilePushReadiness.Blocker) -> String {
        switch blocker {
        case .macStatusUnavailable, .macAdmissionUnavailable:
            return L10n.string(
                "mobile.notifications.status.macUnavailable",
                defaultValue: "Blocked, Mac Status Unavailable"
            )
        case .macAccountMismatch:
            return L10n.string(
                "mobile.notifications.status.accountMismatch",
                defaultValue: "Blocked, Mac Account Does Not Match"
            )
        case .macForwardingDisabled:
            return L10n.string(
                "mobile.notifications.status.macForwardingOff",
                defaultValue: "Blocked, Mac Forwarding Is Off"
            )
        case .macCurrentlyActive:
            return L10n.string(
                "mobile.notifications.status.macActive",
                defaultValue: "Paused, Mac Is Active"
            )
        case .apiOriginMismatch:
            return L10n.string(
                "mobile.notifications.status.originMismatch",
                defaultValue: "Blocked, Mac and iPhone Servers Differ"
            )
        default:
            assertionFailure("Expected a Mac-side push blocker")
            return ""
        }
    }

    private func testStageText(_ stage: MobilePhonePushTestStage) -> String {
        switch stage {
        case .queuedOnMac:
            L10n.string(
                "mobile.notifications.test.queued",
                defaultValue: "Queued on Mac. iOS delivery is still pending."
            )
        case .forwardingDisabled:
            L10n.string(
                "mobile.notifications.test.forwardingOff",
                defaultValue: "Not queued because Mac forwarding is off."
            )
        case .macActive:
            L10n.string(
                "mobile.notifications.test.macActive",
                defaultValue: "Not queued because Only When Away is active and the Mac is in use."
            )
        case .authenticationUnavailable:
            L10n.string(
                "mobile.notifications.test.authentication",
                defaultValue: "Not queued because the Mac is not signed in."
            )
        case .encodingFailed:
            L10n.string(
                "mobile.notifications.test.encodingFailed",
                defaultValue: "The alert could not be prepared for delivery."
            )
        case .queueFull:
            L10n.string(
                "mobile.notifications.test.queueFull",
                defaultValue: "Delivery is busy. Try again shortly."
            )
        case .unavailable:
            L10n.string(
                "mobile.notifications.test.unavailable",
                defaultValue: "The Mac could not confirm a queue stage."
            )
        }
    }

    private var readinessSymbol: String {
        switch readiness {
        case .ready: "checkmark.circle.fill"
        case .limited, .presentationLimited, .reliabilityLimited:
            "exclamationmark.triangle.fill"
        case .blocked: "xmark.circle.fill"
        }
    }

    private var readinessTint: Color {
        switch readiness {
        case .ready: .green
        case .limited, .presentationLimited, .reliabilityLimited: .orange
        case .blocked: .red
        }
    }

}

private extension MobilePushSettingsContent {
    struct RepairPresentation {
        let title: String
        let systemImage: String
        let identifier: String
    }

    func repairPresentation(
        for repair: MobilePushReadiness.Repair
    ) -> RepairPresentation? {
        switch repair {
        case .enableOnPhone:
            RepairPresentation(
                title: L10n.string(
                    "mobile.notifications.repair.enablePhone",
                    defaultValue: "Enable on This iPhone"
                ),
                systemImage: "bell.badge",
                identifier: "MobileSettingsPushRepairEnablePhone"
            )
        case .openSystemSettings:
            RepairPresentation(
                title: L10n.string(
                    "mobile.notifications.repair.openSettings",
                    defaultValue: "Open iOS Notification Settings"
                ),
                systemImage: "gear",
                identifier: "MobileSettingsPushRepairOpenSettings"
            )
        case .retryDeviceTokenRegistration:
            RepairPresentation(
                title: L10n.string(
                    "mobile.notifications.repair.retryAPNs",
                    defaultValue: "Retry Notification Setup"
                ),
                systemImage: "arrow.clockwise",
                identifier: "MobileSettingsPushRepairRetryAPNs"
            )
        case .retryRegistration:
            RepairPresentation(
                title: L10n.string(
                    "mobile.notifications.repair.retryRegistration",
                    defaultValue: "Retry Registration"
                ),
                systemImage: "arrow.clockwise",
                identifier: "MobileSettingsPushRepairRetryRegistration"
            )
        case .signInAgain, .signIntoMatchingAccount:
            RepairPresentation(
                title: L10n.string(
                    "mobile.notifications.repair.signInAgain",
                    defaultValue: "Sign In with the Matching Account"
                ),
                systemImage: "person.crop.circle.badge.exclamationmark",
                identifier: "MobileSettingsPushRepairSignIn"
            )
        case .connectMac:
            RepairPresentation(
                title: L10n.string(
                    "mobile.notifications.repair.connectMac",
                    defaultValue: "Connect a Mac"
                ),
                systemImage: "desktopcomputer",
                identifier: "MobileSettingsPushRepairConnectMac"
            )
        case .leaveMacOrUseAlwaysMode:
            RepairPresentation(
                title: L10n.string(
                    "mobile.notifications.repair.useAlways",
                    defaultValue: "Use Always Mode"
                ),
                systemImage: "bell.fill",
                identifier: "MobileSettingsPushRepairUseAlways"
            )
        case .waitForDeviceToken, .finishAccountDeletion,
             .disablePushOnAnotherDevice, .enableOnMac,
             .rebuildMatchingApps:
            nil
        }
    }
}
#endif
