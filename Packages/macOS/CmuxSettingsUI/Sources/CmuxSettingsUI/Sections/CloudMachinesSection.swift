import CmuxFoundation
import CmuxSettings
import SwiftUI

/// **Cloud Machines** section — the plan card for persistent cloud VMs.
/// Deliberately small: machines are managed from the right-sidebar Machines
/// panel; Settings shows the plan meter and the two entry points (open the
/// panel, manage the plan). Renders nothing when the host doesn't expose
/// Cloud Machines, so the section is invisible to users outside the flag.
@MainActor
public struct CloudMachinesSection: View {
    private let hostActions: SettingsHostActions
    @State private var plan: CloudMachinesPlanSummary?
    @State private var hasLoaded = false
    @State private var hostNotifications: DefaultsValueModel<Bool>

    public init(defaultsStore: UserDefaultsSettingsStore, catalog: SettingCatalog, hostActions: SettingsHostActions) {
        self.hostActions = hostActions
        _hostNotifications = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.cloudMachines.hostNotifications))
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
                    hostNotificationsRow
                }
            }
            .settingsSearchAnchors([
                "setting:cloudMachines:plan",
                "setting:cloudMachines:open-panel",
                "setting:cloudMachines:host-notifications",
            ])
            .task {
                hostNotifications.startObserving()
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
                hostActions.openCloudMachinesBilling()
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

    @ViewBuilder
    private var hostNotificationsRow: some View {
        SettingsCardRow(
            configurationReview: .json("cloud.vmHostNotifications.enabled"),
            searchAnchorID: "setting:cloudMachines:host-notifications",
            String(localized: "settings.cloudMachines.hostNotifications.title", defaultValue: "Notifications from machines"),
            subtitle: hostNotifications.current
                ? String(localized: "settings.cloudMachines.hostNotifications.subtitleOn", defaultValue: "Your machines can send notifications, titles, and agent status to this Mac over your private Cloud VM network while the tunnel is up.")
                : String(localized: "settings.cloudMachines.hostNotifications.subtitleOff", defaultValue: "This Mac accepts nothing from your machines. Turn on to let agents in Cloud VMs notify you here.")
        ) {
            Toggle("", isOn: Binding(get: { hostNotifications.current }, set: { hostNotifications.set($0) }))
                .labelsHidden()
                .controlSize(.small)
                .accessibilityIdentifier("SettingsCloudMachinesHostNotificationsToggle")
        }
    }

    private var planSubtitle: String {
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
        if let plan, !plan.isPaidPlan {
            return String(localized: "settings.cloudMachines.plan.upgrade", defaultValue: "Upgrade…")
        }
        return String(localized: "settings.cloudMachines.plan.manage", defaultValue: "Manage…")
    }
}
