import SwiftUI

/// **Cloud Machines** section — the plan card for persistent cloud VMs.
/// Deliberately small: machines are managed from the right-sidebar Machines
/// panel; Settings also exposes the plan and optional system VPN setup.
/// Renders nothing when the host doesn't expose
/// Cloud Machines, so the section is invisible to users outside the flag.
@MainActor
public struct CloudMachinesSection: View {
    private let hostActions: SettingsHostActions
    @State private var plan: CloudMachinesPlanSummary?
    @State private var hasLoaded = false

    public init(hostActions: SettingsHostActions) {
        self.hostActions = hostActions
    }

    public var body: some View {
        if hostActions.isCloudMachinesAvailable {
            SettingsSectionHeader(
                String(localized: "settings.section.cloudMachines", defaultValue: "Cloud"),
                section: .cloudMachines
            )
            SettingsCard {
                VStack(alignment: .leading, spacing: 0) {
                    planRow
                    Divider().padding(.horizontal, 14)
                    panelRow
                    Divider().padding(.horizontal, 14)
                    vpnRow
                }
            }
            .settingsSearchAnchors([
                "setting:cloudMachines:plan",
                "setting:cloudMachines:open-panel",
                "setting:cloudMachines:vpn",
            ])
            .task {
                plan = await hostActions.cloudMachinesPlanSummary()
                hasLoaded = true
            }
        }
    }

    private var planRow: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "settings.cloudMachines.plan.title", defaultValue: "Plan"))
                Text(planSubtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button(manageButtonTitle) {
                if hostActions.isCloudMachinesEnabled {
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
                .font(.system(size: 11))
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
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button(vpnActionTitle) {
                if hostActions.isCloudMachinesEnabled {
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
        guard hostActions.isCloudMachinesEnabled else {
            return String(
                localized: "settings.cloudMachines.plan.enableFirst",
                defaultValue: "Open the Machines tab to enable Cloud."
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
        guard hostActions.isCloudMachinesEnabled else {
            return String(localized: "settings.cloudMachines.plan.enable", defaultValue: "Enable…")
        }
        if let plan, !plan.isPaidPlan {
            return String(localized: "settings.cloudMachines.plan.upgrade", defaultValue: "Upgrade…")
        }
        return String(localized: "settings.cloudMachines.plan.manage", defaultValue: "Manage…")
    }

    private var vpnDescription: String {
        if hostActions.isCloudMachinesEnabled {
            return String(
                localized: "cloud.vpn.setup.howItWorks.body",
                defaultValue: "Connect Safari, Chrome, and other apps to your Cloud machines. Each machine keeps its private IP address and original ports. Only traffic to your Cloud network uses this encrypted connection. cmux terminals, Ports, and Desktop work without it."
            )
        }
        return String(
            localized: "settings.cloudMachines.vpn.enableFirst",
            defaultValue: "Enable Cloud in the Machines tab before setting up private IP access."
        )
    }

    private var vpnActionTitle: String {
        hostActions.isCloudMachinesEnabled
            ? String(localized: "cloudTree.ports.setupVPN", defaultValue: "Set Up VPN…")
            : String(localized: "settings.cloudMachines.vpn.openMachines", defaultValue: "Open Machines")
    }
}
