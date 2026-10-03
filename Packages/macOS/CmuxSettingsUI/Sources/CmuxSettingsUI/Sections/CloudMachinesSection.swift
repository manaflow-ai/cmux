import AppKit
import CmuxFoundation
import SwiftUI

/// **Cloud Machines** settings: first-use activation, plan details, and
/// optional system VPN setup. The activation control calls the host's shared
/// coordinator so Settings and the right-sidebar onboarding screen cannot
/// perform different setup work.
@MainActor
public struct CloudMachinesSection: View {
    private let hostActions: SettingsHostActions
    @State private var activationState: CloudMachinesActivationState
    @State private var plan: CloudMachinesPlanSummary?
    @State private var hasLoaded = false
    /// Free accounts get Upgrade in place of the Enable toggle; nil until the
    /// plan answers (or when signed out), which keeps the toggle.
    @State private var planIncludesCloud: Bool?
    /// Bumped when the app comes back to the front, e.g. after upgrading in
    /// the browser, so the row stops offering Upgrade without a restart.
    @State private var planCheckGeneration = 0

    public init(hostActions: SettingsHostActions) {
        self.hostActions = hostActions
        _activationState = State(initialValue: hostActions.cloudMachinesActivationState)
    }

    public var body: some View {
        if hostActions.isCloudMachinesAvailable {
            SettingsSectionHeader(
                String(localized: "settings.section.cloudMachines", defaultValue: "Cloud"),
                section: .cloudMachines
            )
            SettingsCard {
                activationRow
                // Plan, machines and VPN all need Cloud on; before that each
                // could only say "Open Machines", so they wait until it is.
                if activationState.isEnabled {
                    SettingsCardDivider()
                    planRow
                    SettingsCardDivider()
                    panelRow
                    SettingsCardDivider()
                    vpnRow
                }
            }
            .settingsSearchAnchors(
                activationState.isEnabled
                    ? [
                        "setting:cloudMachines:enable",
                        "setting:cloudMachines:plan",
                        "setting:cloudMachines:open-panel",
                        "setting:cloudMachines:vpn",
                    ]
                    : ["setting:cloudMachines:enable"]
            )
            .task { await observeActivation() }
            .task(id: PlanCheckKey(
                showsEnableToggle: showsEnableToggle,
                accountID: hostActions.cloudMachinesAccountID,
                generation: planCheckGeneration
            )) {
                guard showsEnableToggle, hostActions.cloudMachinesAccountID != nil else {
                    planIncludesCloud = nil
                    return
                }
                planIncludesCloud = await hostActions.cloudMachinesPlanIncludesCloud()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                planCheckGeneration &+= 1
            }
            .task(id: activationState.isEnabled) {
                plan = nil
                hasLoaded = false
                guard activationState.isEnabled else { return }
                let loaded = await hostActions.cloudMachinesPlanSummary()
                guard !Task.isCancelled, activationState.isEnabled else { return }
                plan = loaded
                hasLoaded = true
            }
        }
    }

    private var activationRow: some View {
        SettingsCardRow(
            searchAnchorID: "setting:cloudMachines:enable",
            String(localized: "settings.cloudMachines.enable.title.enable", defaultValue: "Enable Cloud Machines"),
            subtitle: activationSubtitle
        ) {
            activationControl
        }
        .accessibilityIdentifier("SettingsCloudEnableRow")
    }

    @ViewBuilder
    private var activationControl: some View {
        switch activationState {
        case .disabled where planIncludesCloud == false, .cancelled where planIncludesCloud == false:
            Button(String(localized: "settings.cloudMachines.enable.upgrade", defaultValue: "Upgrade")) {
                hostActions.openCloudMachinesBilling()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("SettingsCloudEnableUpgrade")
        case .disabled, .cancelled:
            Toggle(
                "",
                isOn: Binding(
                    get: { false },
                    set: { if $0 { hostActions.enableCloudMachines() } }
                )
            )
            .labelsHidden()
            .controlSize(.small)
            .accessibilityLabel(String(localized: "settings.cloudMachines.enable.title.enable", defaultValue: "Enable Cloud Machines"))
            .accessibilityIdentifier("SettingsCloudEnableToggle")
        case .enabling:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(String(localized: "settings.cloudMachines.enable.loading", defaultValue: "Enabling Cloud"))
                Button(String(localized: "settings.cloudMachines.enable.cancel", defaultValue: "Cancel")) {
                    hostActions.cancelCloudMachinesActivation()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("SettingsCloudEnableCancel")
            }
        case .enabled:
            Toggle(
                "",
                isOn: Binding(
                    get: { true },
                    set: { if !$0 { hostActions.disableCloudMachines() } }
                )
            )
            .labelsHidden()
            .controlSize(.small)
            .accessibilityLabel(String(localized: "settings.cloudMachines.enable.title.enable", defaultValue: "Enable Cloud Machines"))
            .accessibilityIdentifier("SettingsCloudEnableToggle")
        case .failed(let failure):
            HStack(spacing: 8) {
                if case .requiresPro = failure {
                    Button(String(localized: "settings.cloudMachines.enable.upgrade", defaultValue: "Upgrade")) {
                        hostActions.openCloudMachinesBilling()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else if case .signInRequired = failure {
                    Button(String(localized: "settings.cloudMachines.enable.signIn", defaultValue: "Sign In")) {
                        hostActions.signInForCloudMachines()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Button(String(localized: "machines.unavailable.retry", defaultValue: "Retry")) {
                    hostActions.retryCloudMachinesActivation()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("SettingsCloudEnableRetry")
            }
        case .unavailable:
            Image(systemName: "lock.slash")
                .foregroundStyle(.secondary)
                .accessibilityLabel(String(localized: "settings.cloudMachines.enable.unavailable", defaultValue: "Cloud unavailable"))
        }
    }

    private struct PlanCheckKey: Equatable {
        let showsEnableToggle: Bool
        let accountID: String?
        let generation: Int
    }

    /// Cloud is off, so the row offers to turn it on (or to upgrade first).
    private var showsEnableToggle: Bool {
        switch activationState {
        case .disabled, .cancelled: return true
        default: return false
        }
    }

    private var activationSubtitle: String {
        switch activationState {
        case .disabled where planIncludesCloud == false, .cancelled where planIncludesCloud == false:
            return String(
                localized: "settings.cloudMachines.enable.requiresPro.subtitle",
                defaultValue: "Your current plan does not include Cloud machine access."
            )
        case .disabled, .cancelled:
            return String(
                localized: "settings.cloudMachines.enable.subtitle",
                defaultValue: "Prepare Cloud once to list and create persistent cloud computers."
            )
        case .enabling:
            return String(
                localized: "settings.cloudMachines.enable.loading.subtitle",
                defaultValue: "Preparing the shared Cloud connection…"
            )
        case .enabled:
            return String(
                localized: "settings.cloudMachines.enable.enabled.subtitle",
                defaultValue: "Cloud machines are ready to use."
            )
        case .failed(.requiresPro):
            return String(
                localized: "settings.cloudMachines.enable.requiresPro.subtitle",
                defaultValue: "Your current plan does not include Cloud machine access."
            )
        case .failed(.signInRequired):
            return String(
                localized: "settings.cloudMachines.enable.signIn.subtitle",
                defaultValue: "Sign in to your cmux account, then retry Cloud setup."
            )
        case .failed(.serviceUnavailable):
            return String(
                localized: "settings.cloudMachines.enable.failed.subtitle",
                defaultValue: "Cloud setup could not finish. Check your connection and retry."
            )
        case .unavailable:
            return String(
                localized: "settings.cloudMachines.enable.unavailable.subtitle",
                defaultValue: "Cloud Machines are unavailable on this Mac right now."
            )
        }
    }

    private var planRow: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "settings.cloudMachines.plan.title", defaultValue: "Plan"))
                Text(planSubtitle)
                    .cmuxFont(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button(manageButtonTitle) {
                if activationState.isEnabled {
                    hostActions.openCloudMachinesBilling()
                } else {
                    hostActions.openCloudMachinesPanel()
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .id("setting:cloudMachines:plan")
    }

    private var panelRow: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "settings.cloudMachines.panel.title", defaultValue: "Your machines"))
                Text(String(
                    localized: "settings.cloudMachines.panel.subtitle",
                    defaultValue: "Persistent cloud computers. Files survive forever; sleeping machines cost nothing."
                ))
                .cmuxFont(.caption)
                .foregroundColor(.secondary)
            }
            Spacer()
            Button(String(localized: "settings.cloudMachines.panel.open", defaultValue: "Open Machines")) {
                hostActions.openCloudMachinesPanel()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .id("setting:cloudMachines:open-panel")
    }

    private var vpnRow: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "cloud.vpn.setup.entry.subtitle", defaultValue: "Optional private IP access for other apps"))
                Text(vpnDescription)
                    .cmuxFont(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button(vpnActionTitle) {
                if activationState.isEnabled {
                    hostActions.openCloudVPNSetup()
                } else {
                    hostActions.openCloudMachinesPanel()
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("SettingsCloudVPNSetup")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .id("setting:cloudMachines:vpn")
    }

    private var planSubtitle: String {
        guard activationState.isEnabled else {
            return String(
                localized: "settings.cloudMachines.plan.enableFirst",
                defaultValue: "Enable Cloud above to view your plan."
            )
        }
        guard let plan else {
            return hasLoaded
                ? String(localized: "settings.cloudMachines.plan.unavailable", defaultValue: "Sign in to see your plan.")
                : String(localized: "settings.cloudMachines.plan.loading", defaultValue: "Loading…")
        }
        guard let maxMachines = plan.maxMachines else {
            let format = String(
                localized: "settings.cloudMachines.plan.summary.unlimited",
                defaultValue: "%1$@ · %2$d machines, no limit"
            )
            return String(format: format, plan.planLabel, plan.activeMachines)
        }
        let format = String(
            localized: "settings.cloudMachines.plan.summary",
            defaultValue: "%1$@ · %2$d of %3$d machines"
        )
        return String(format: format, plan.planLabel, plan.activeMachines, maxMachines)
    }

    private var manageButtonTitle: String {
        guard activationState.isEnabled else {
            return String(localized: "settings.cloudMachines.plan.openMachines", defaultValue: "Open Machines")
        }
        if let plan, !plan.isPaidPlan {
            return String(localized: "settings.cloudMachines.plan.upgrade", defaultValue: "Upgrade…")
        }
        return String(localized: "settings.cloudMachines.plan.manage", defaultValue: "Manage…")
    }

    private var vpnDescription: String {
        if activationState.isEnabled {
            return String(
                localized: "cloud.vpn.setup.howItWorks.body",
                defaultValue: "Connect Safari, Chrome, and other apps to your Cloud machines. Each machine keeps its private IP address and original ports. Only traffic to your Cloud network uses this encrypted connection. cmux terminals, Ports, and Desktop work without it."
            )
        }
        return String(
            localized: "settings.cloudMachines.vpn.enableFirst",
            defaultValue: "Enable Cloud above before setting up private IP access."
        )
    }

    private var vpnActionTitle: String {
        activationState.isEnabled
            ? String(localized: "cloudTree.ports.setupVPN", defaultValue: "Set Up VPN…")
            : String(localized: "settings.cloudMachines.vpn.openMachines", defaultValue: "Open Machines")
    }

    private func observeActivation() async {
        for await state in hostActions.cloudMachinesActivationUpdates() {
            guard !Task.isCancelled else { return }
            activationState = state
        }
    }
}
