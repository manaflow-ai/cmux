#if os(iOS)
import CmuxMobileBilling
import CmuxMobileBillingUI
public import CmuxMobileCloud
import CmuxMobileSupport
import Foundation
import SwiftUI

/// The Cloud tab's machine list: where machines are listed, created and
/// inspected. A machine's terminals open from the Workspaces tab alongside
/// every other computer's, so rows here do not navigate.
///
/// HIG: Lists and tables (inset-grouped list of machines) and Loading (a
/// progress row while the list loads, and while the tunnel comes up once there
/// is a machine to reach).
///
/// The tunnel's lifecycle is owned by ``CloudSessionController``, leased by
/// the composition root while the account owns a machine; this view only
/// reflects it.
public struct CloudSectionView: View {
    @State private var controller: CloudSessionController
    @Environment(\.cloudSystemVPNController) private var systemVPN
    /// App Store billing; when present, Free accounts see the upgrade
    /// banner and New Machine opens the paywall.
    @Environment(BillingModel.self) private var billing: BillingModel?
    @State private var isCreateSheetPresented = false
    @State private var paywall: BillingEntryPoint?

    /// Creates the section over a session controller.
    public init(controller: CloudSessionController) {
        _controller = State(initialValue: controller)
    }

    public var body: some View {
        List {
            upgradeSection
            tunnelSection
            machinesSection
            systemVPNSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.string("mobile.cloud.title", defaultValue: "Cloud"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            controller.refreshMachines()
            controller.retryConnections()
        }
        .sheet(isPresented: $isCreateSheetPresented) {
            CloudCreateMachineSheet(
                controller: controller,
                availableKinds: controller.availableMachineKinds,
                limits: controller.machineLimits
            )
        }
        .billingPaywall($paywall, onDismiss: {
            // A new plan changes the machine limits.
            controller.refreshMachines()
        })
        .task { await billing?.loadIfNeeded() }
    }

    /// The upgrade banner for a Free account that may buy in the App Store,
    /// above the machine list. Hidden for paid plans, web or team billing,
    /// and builds that sell nothing.
    @ViewBuilder
    private var upgradeSection: some View {
        if billing?.canOfferUpgrade == true {
            Section {
                MobileUpgradeCard(
                    entryPoint: .cloudBanner,
                    title: L10n.string("mobile.billing.upgrade.cloud.title", defaultValue: "Cloud VMs need a paid plan"),
                    message: L10n.string(
                        "mobile.billing.upgrade.cloud.message",
                        defaultValue: "Pro includes up to 5 Cloud VMs sharing 20 vCPUs and 40 GB RAM."
                    ),
                    open: { paywall = .cloudBanner }
                )
            }
        }
    }

    /// New Machine for a Free account whose plan allows no machine opens the
    /// paywall instead of a create sheet that can only fail.
    private var newMachineNeedsPlan: Bool {
        // Only on the server's word: before the limits load, the create
        // sheet opens as before.
        guard billing?.canOfferUpgrade == true, let limits = controller.machineLimits else { return false }
        return limits.maxActiveMachines == 0
    }

    private func resume(_ machine: CloudMachine) async {
        let resumed = await controller.resumeMachine(machine)
        if !resumed, controller.lastMachineActionFailure?.failure.isPlanLimit == true,
           billing?.canOfferPlanChange == true {
            paywall = .limit
        }
    }

    /// The system VPN only matters once there is a machine to reach, but stays
    /// visible while it is on so it can always be turned off here.
    @ViewBuilder
    private var systemVPNSection: some View {
        if let systemVPN, !controller.machines.elements.isEmpty || systemVPN.phase != .off {
            CloudSystemVPNSection(
                phase: systemVPN.phase,
                isAvailable: systemVPN.isAvailable,
                enable: { systemVPN.enable() },
                disable: { systemVPN.disable() },
                retry: { systemVPN.retry() }
            )
        }
    }

    /// The tunnel only matters once there is a machine to reach; listing and
    /// creating machines are control-plane calls that need none. An account
    /// with no machines never starts a tunnel, so an idle tunnel is not
    /// "connecting" and shows nothing.
    @ViewBuilder
    private var tunnelSection: some View {
        if !controller.machines.elements.isEmpty {
            switch controller.tunnel {
            case .starting:
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(L10n.string("mobile.cloud.tunnel.connecting", defaultValue: "Connecting to your private network"))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("CloudTunnelConnecting")
                }
            case .failed(let failure):
                Section {
                    CloudFailureRow(failure: failure, retry: { controller.retryTunnel() })
                }
            case .idle, .ready:
                EmptyView()
            }
        }
    }

    /// Rendered from the list's own phase, never the tunnel's.
    @ViewBuilder
    private var machinesSection: some View {
        let machines = controller.machines.elements
        switch controller.machines {
        case .idle, .loading where machines.isEmpty:
            Section { loadingRow }
        case .failed(let failure, _) where machines.isEmpty:
            Section { CloudFailureRow(failure: failure, retry: { controller.refreshMachines() }) }
        default:
            if machines.isEmpty {
                // A Free account's empty list is the upgrade banner above.
                if billing?.canOfferUpgrade != true {
                    Section {
                        Text(L10n.string("mobile.cloud.empty.create", defaultValue: "No Cloud machines yet. Create one below."))
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("CloudMachinesEmpty")
                    }
                }
            } else {
                Section {
                    // Rows do not navigate: a machine's terminals live in the
                    // Workspaces tab with every other computer's, so there is
                    // no second terminal experience to push to from here.
                    ForEach(machines) { machine in
                        CloudMachineRow(
                            machine: machine,
                            isBusy: controller.machineActionsInFlight.contains(machine.id),
                            failure: controller.lastMachineActionFailure?.machineID == machine.id
                                ? controller.lastMachineActionFailure
                                : nil,
                            connectionFailure: machine.isRunning
                                ? controller.connectionFailure(for: machine.id)
                                : nil,
                            retryConnection: { controller.retryConnections() },
                            pause: { Task { await controller.pauseMachine(machine) } },
                            resume: { Task { await resume(machine) } },
                            restart: { Task { await controller.restartMachine(machine) } },
                            delete: { Task { await controller.deleteMachine(machine) } }
                        )
                    }
                } header: {
                    Text(L10n.string("mobile.cloud.machines.header", defaultValue: "Machines"))
                } footer: {
                    Text(
                        L10n.string(
                            "mobile.cloud.machines.footer",
                            defaultValue: "Cloud machines appear in your computers, and their workspaces open in the Workspaces tab."
                        )
                    )
                }
                if case .failed(let failure, _) = controller.machines {
                    Section { CloudFailureRow(failure: failure, retry: { controller.refreshMachines() }) }
                }
            }
        }
        createMachineSection
    }

    private var createMachineSection: some View {
        Section {
            Button {
                if newMachineNeedsPlan {
                    paywall = .cloudNewMachine
                } else {
                    isCreateSheetPresented = true
                }
            } label: {
                Label(
                    L10n.string("mobile.cloud.machines.new", defaultValue: "New cloud machine"),
                    systemImage: "plus"
                )
            }
            .accessibilityIdentifier("CloudCreateMachineButton")
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(L10n.string("mobile.cloud.machines.loading", defaultValue: "Loading machines"))
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("CloudMachinesLoading")
    }
}

/// The Cloud equivalent of the Mac New Machine sheet.
///
/// The backend remains the source of truth for team, provider, image, and
/// billing checks. The phone shows the same size ladder and sends the selected
/// memory profile when the user confirms.
struct CloudCreateMachineSheet: View {
    let controller: CloudSessionController
    let availableKinds: Set<CloudMachineKind>?
    let limits: CloudMachineLimits?
    @Environment(\.dismiss) private var dismiss
    /// App Store billing; when present, upgrade actions open the in-app plans
    /// sheet. Without it the locked sizes stay as plain text: the App Store
    /// build never links to a web purchase page (App Review Guideline 3.1.1).
    @Environment(BillingModel.self) private var billing: BillingModel?
    @State private var selectedMemoryMb: Int
    @State private var paywall: BillingEntryPoint?

    init(
        controller: CloudSessionController,
        availableKinds: Set<CloudMachineKind>?,
        limits: CloudMachineLimits?
    ) {
        self.controller = controller
        self.availableKinds = availableKinds
        self.limits = limits
        _selectedMemoryMb = State(initialValue: Self.defaultMemoryMb(for: limits))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(L10n.string(
                        "mobile.cloud.create.description",
                        defaultValue: "A cloud computer with devtools and coding agents preinstalled. Its home directory is reset when the machine is recreated."
                    ))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Section {
                    Menu {
                        ForEach(availableMemoryOptions, id: \.self) { memoryMb in
                            Button(sizeMenuTitle(memoryMb)) {
                                selectedMemoryMb = memoryMb
                            }
                        }
                        ForEach(lockedMemoryOptions, id: \.self) { memoryMb in
                            Button {
                                openPlans()
                            } label: {
                                Label(lockedSizeMenuTitle(memoryMb), systemImage: "lock.fill")
                            }
                            .disabled(billing?.canOfferPlanChange != true)
                            .accessibilityIdentifier("CloudCreateMachineLockedSize.\(memoryMb)")
                        }
                    } label: {
                        HStack {
                            Text(sizeMenuTitle(selectedMemoryMb))
                            Spacer(minLength: 12)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(availableMemoryOptions.isEmpty)
                    .accessibilityIdentifier("CloudCreateMachineSize")

                    if let lockedSizesNote {
                        HStack(alignment: .center, spacing: 8) {
                            Text(lockedSizesNote)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            if billing?.canOfferPlanChange == true, let upgradeActionTitle {
                                Button(upgradeActionTitle) {
                                    openPlans()
                                }
                                .controlSize(.small)
                                .buttonStyle(.bordered)
                                .font(.footnote.weight(.semibold))
                                .billingUpgradeEntryViewed(.lockedMachineSize)
                                .accessibilityIdentifier("CloudCreateMachineUpgrade")
                            }
                        }
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.string("mobile.cloud.create.size.label", defaultValue: "Machine size"))
                        Text(L10n.string(
                            "mobile.cloud.create.size.help",
                            defaultValue: "Choose the memory and disk profile for this machine."
                        ))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }

                if machineUsageText != nil || poolUsageText != nil {
                    Section {
                        if let machineUsageText {
                            Text(machineUsageText)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("CloudCreateMachineUsage")
                        }
                        if let poolUsageText {
                            Text(poolUsageText)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("CloudCreateMachinePoolUsage")
                        }
                    }
                }

                Section {
                    Button {
                        Task {
                            let created = await controller.createMachine(options: .init(
                                kind: machineKind,
                                memoryMb: selectedMemoryMb
                            ))
                            if created != nil {
                                dismiss()
                            } else if controller.lastCreateFailure?.isPlanLimit == true,
                                      billing?.canOfferPlanChange == true {
                                paywall = .limit
                            }
                        }
                    } label: {
                        HStack {
                            Text(L10n.string("mobile.cloud.create.submit", defaultValue: "Create"))
                            if controller.isCreatingMachine {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(controller.isCreatingMachine || availableMemoryOptions.isEmpty)
                    .accessibilityIdentifier("CloudCreateMachineSubmit")

                    if let failure = controller.lastCreateFailure {
                        Text(failure.localizedMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if let action = failure.action, !action.isEmpty {
                            Text(action)
                                .font(.footnote)
                                .foregroundStyle(.primary)
                        }
                        #if DEBUG
                        Text(failure.detail)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("CloudCreateMachineFailure")
                        #endif
                    }
                } footer: {
                    if controller.isCreatingMachine {
                        Text(L10n.string(
                            "mobile.cloud.create.wait",
                            defaultValue: "Creating your machine. This takes a moment."
                        ))
                    } else {
                        Text(L10n.string(
                            "mobile.cloud.create.backgroundNote",
                            defaultValue: "Creation continues in the Machines panel."
                        ))
                    }
                }
            }
            .navigationTitle(L10n.string("mobile.cloud.create.title", defaultValue: "New Machine"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("mobile.cloud.cancel", defaultValue: "Cancel")) { dismiss() }
                        .disabled(controller.isCreatingMachine)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .billingPaywall($paywall, onDismiss: {
            // A new plan changes the size ladder and machine limits.
            controller.refreshMachines()
        })
    }

    private static let fallbackMemoryMb = 8192

    private var machineKind: CloudMachineKind {
        if let availableKinds, !availableKinds.contains(.desktop) {
            return .base
        }
        return .defaultKind
    }

    private var availableMemoryOptions: [Int] {
        let options = limits?.memoryOptionsMb ?? []
        let validOptions = options.filter { Self.diskMb(for: $0) != nil }.sorted()
        return validOptions.isEmpty ? [Self.fallbackMemoryMb] : validOptions
    }

    private var lockedMemoryOptions: [Int] {
        (limits?.lockedMemoryOptionsMb ?? [])
            .filter { Self.diskMb(for: $0) != nil }
            .sorted()
    }

    private var lockedSizesNote: String? {
        guard !lockedMemoryOptions.isEmpty, let planNames = lockedMemoryUpgradePlanNames else { return nil }
        let sizes = lockedMemoryOptions.compactMap { memoryMb in
            upgradePlanID(for: memoryMb) == nil ? nil : memoryLabel(memoryMb)
        }
        guard !sizes.isEmpty else { return nil }
        let sizeList = ListFormatter.localizedString(byJoining: sizes)
        return String(
            format: L10n.string(
                "mobile.cloud.create.size.lockedNote",
                defaultValue: "%1$@ machines need cmux %2$@."
            ),
            sizeList,
            planNames
        )
    }

    private var lockedMemoryUpgradePlanIDs: [String] {
        lockedMemoryOptions.compactMap { upgradePlanID(for: $0) }.reduce(into: [String]()) { result, planID in
            if !result.contains(planID) { result.append(planID) }
        }
    }

    private var lockedMemoryUpgradePlanNames: String? {
        let names = lockedMemoryUpgradePlanIDs.map(planDisplayName)
        guard !names.isEmpty else { return nil }
        return ListFormatter.localizedString(byJoining: names)
    }

    private var upgradeActionTitle: String? {
        guard let planNames = lockedMemoryUpgradePlanNames else { return nil }
        if lockedMemoryUpgradePlanIDs == ["max"] {
            return L10n.string("mobile.cloud.create.size.upgrade", defaultValue: "Upgrade to Max")
        }
        return String(
            format: L10n.string(
                "mobile.cloud.create.size.upgradeFormat",
                defaultValue: "Upgrade to %@"
            ),
            planNames
        )
    }

    private var machineUsageText: String? {
        guard let limits else { return nil }
        let activeCount = limits.activeMachineCount
            ?? controller.machines.elements.filter {
                $0.lifecycle == .running || $0.lifecycle == .provisioning
            }.count
        if let maximum = limits.maxActiveMachines {
            return String(
                format: L10n.string(
                    "mobile.cloud.create.usage",
                    defaultValue: "%1$d of %2$d machines in use"
                ),
                activeCount,
                maximum
            )
        }
        return String(
            format: L10n.string(
                "mobile.cloud.create.usageUnlimited",
                defaultValue: "%d machines in use"
            ),
            activeCount
        )
    }

    /// The shared pool's usage, "16 of 20 vCPUs · 32 of 40 GB RAM in use";
    /// nil for plans without a pool and control planes that predate it.
    private var poolUsageText: String? {
        guard let pool = limits?.resourcePool else { return nil }
        return String(
            format: L10n.string(
                "cloud.pool.usage",
                defaultValue: "%1$lld of %2$lld vCPUs · %3$lld of %4$lld GB RAM in use"
            ),
            Int64(pool.usedVcpus),
            Int64(pool.poolVcpus),
            Int64(pool.usedMemoryMb / 1024),
            Int64(pool.poolMemoryMb / 1024)
        )
    }

    private func sizeMenuTitle(_ memoryMb: Int) -> String {
        let format = L10n.string(
            "mobile.cloud.create.size.menu",
            defaultValue: "%1$d GB RAM · %2$d GB disk"
        )
        return String(format: format, memoryMb / 1024, (Self.diskMb(for: memoryMb) ?? memoryMb) / 1024)
    }

    private func lockedSizeMenuTitle(_ memoryMb: Int) -> String {
        guard let planID = upgradePlanID(for: memoryMb) else { return sizeMenuTitle(memoryMb) }
        return String(
            format: L10n.string(
                "mobile.cloud.create.size.lockedMenu",
                defaultValue: "%1$@ · Requires %2$@"
            ),
            sizeMenuTitle(memoryMb),
            planDisplayName(planID)
        )
    }

    private func upgradePlanID(for memoryMb: Int) -> String? {
        if let planID = limits?.memoryUpgradePlansByMb?[String(memoryMb)] {
            return normalizedPlanID(planID)
        }
        guard let planID = limits?.memoryUpgradePlanID else { return nil }
        return normalizedPlanID(planID)
    }

    private func normalizedPlanID(_ planID: String) -> String {
        planID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func planDisplayName(_ planID: String) -> String {
        switch normalizedPlanID(planID) {
        case "max":
            return L10n.string("mobile.cloud.create.plan.max", defaultValue: "Max")
        case "pro":
            return "Pro"
        default:
            return planID.trimmingCharacters(in: .whitespacesAndNewlines).capitalized
        }
    }

    private func memoryLabel(_ memoryMb: Int) -> String {
        String(
            format: L10n.string("mobile.cloud.create.size.gb", defaultValue: "%d GB"),
            memoryMb / 1024
        )
    }

    private static func defaultMemoryMb(for limits: CloudMachineLimits?) -> Int {
        let available = (limits?.memoryOptionsMb ?? [])
            .filter { diskMb(for: $0) != nil }
            .sorted()
        return available.contains(fallbackMemoryMb) ? fallbackMemoryMb : (available.first ?? fallbackMemoryMb)
    }

    private static func diskMb(for memoryMb: Int) -> Int? {
        switch memoryMb {
        case 4096: return 16384
        case 8192: return 32768
        case 16384: return 65536
        case 24576: return 98304
        case 32768: return 131072
        case 65536: return 131072
        default: return nil
        }
    }

    /// Opens the paywall. Plans are sold only in app (App Review Guideline
    /// 3.1.1), so without a billing model, or for an account that cannot
    /// buy, this does nothing.
    private func openPlans() {
        guard billing?.canOfferPlanChange == true else { return }
        paywall = .lockedMachineSize
    }
}

/// One machine row: its name and a lowercased status line.
struct CloudMachineRow: View {
    let machine: CloudMachine
    /// A pause, resume, restart or delete is running for this machine.
    let isBusy: Bool
    /// The last lifecycle failure, when it hit this machine.
    let failure: CloudMachineActionFailure?
    /// Why the machine's terminal service could not be reached, while it is
    /// running but unreachable. The bridge keeps retrying on its own.
    let connectionFailure: CloudSessionFailure?
    let retryConnection: () -> Void
    let pause: () -> Void
    let resume: () -> Void
    let restart: () -> Void
    let delete: () -> Void
    @State private var isDeleteConfirmationPresented = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "cloud")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(machine.preferredName)
                    .font(.body)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .accessibilityIdentifier("CloudMachineStatus")
                if let failure {
                    Text(failureText(failure))
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("CloudMachineActionFailure")
                }
                if let connectionFailure {
                    Text(L10n.string(
                        "mobile.cloud.machine.connectFailed",
                        defaultValue: "Couldn't connect. Retrying automatically."
                    ))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("CloudMachineConnectionFailure")
                    Text(connectionReason(connectionFailure))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("CloudMachineConnectionReason")
                }
            }
            Spacer(minLength: 0)
            if isBusy {
                ProgressView()
                    .accessibilityIdentifier("CloudMachineBusy")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("CloudMachineRow")
        .contextMenu { actions }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if machine.lifecycle.canDelete {
                // This action presents a confirmation. The button itself is
                // intentionally non-destructive so SwiftUI does not remove
                // the row before the server has confirmed deletion.
                Button(action: requestDelete) {
                    Label(L10n.string("mobile.cloud.action.delete", defaultValue: "Delete"), systemImage: "trash")
                }
                .tint(.red)
                .disabled(isBusy)
            }
            if machine.lifecycle.canPause {
                Button(action: pause) {
                    Label(L10n.string("mobile.cloud.action.pause", defaultValue: "Pause"), systemImage: "pause.circle")
                }
                .tint(.orange)
                .disabled(isBusy)
            }
            if machine.lifecycle.canResume {
                Button(action: resume) {
                    Label(L10n.string("mobile.cloud.action.resume", defaultValue: "Resume"), systemImage: "play.circle")
                }
                .tint(.green)
                .disabled(isBusy)
            }
            if machine.canRestart {
                Button(action: restart) {
                    Label(L10n.string("mobile.cloud.action.restart", defaultValue: "Restart"), systemImage: "arrow.counterclockwise.circle")
                }
                .tint(.blue)
                .disabled(isBusy)
            }
        }
        .confirmationDialog(
            String(
                format: L10n.string(
                    "mobile.cloud.delete.titleFormat",
                    defaultValue: "Delete %@?"
                ),
                machine.preferredName
            ),
            isPresented: $isDeleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(
                L10n.string("mobile.cloud.action.delete", defaultValue: "Delete"),
                role: .destructive,
                action: delete
            )
            .accessibilityIdentifier("CloudDeleteMachineConfirm")
        } message: {
            Text(L10n.string(
                "mobile.cloud.delete.message",
                defaultValue: "This permanently deletes the machine and its disk, including its terminals and files."
            ))
        }
    }

    private func requestDelete() {
        isDeleteConfirmationPresented = true
    }

    @ViewBuilder
    private var actions: some View {
        if connectionFailure != nil {
            Button(action: retryConnection) {
                Label(
                    L10n.string("mobile.cloud.action.retryNow", defaultValue: "Try Again Now"),
                    systemImage: "arrow.clockwise"
                )
            }
        }
        if machine.lifecycle.canResume {
            Button(action: resume) {
                Label(L10n.string("mobile.cloud.action.resume", defaultValue: "Resume"), systemImage: "play.circle")
            }
            .disabled(isBusy)
        }
        if machine.lifecycle.canPause {
            Button(action: pause) {
                Label(L10n.string("mobile.cloud.action.pause", defaultValue: "Pause"), systemImage: "pause.circle")
            }
            .disabled(isBusy)
        }
        if machine.canRestart {
            Button(action: restart) {
                Label(L10n.string("mobile.cloud.action.restart", defaultValue: "Restart"), systemImage: "arrow.counterclockwise.circle")
            }
            .disabled(isBusy)
        }
        if machine.lifecycle.canDelete {
            Button(action: requestDelete) {
                Label(L10n.string("mobile.cloud.action.delete", defaultValue: "Delete"), systemImage: "trash")
            }
            .disabled(isBusy)
        }
    }

    private var statusText: String {
        switch machine.lifecycle {
        case .running: return L10n.string("mobile.cloud.status.running", defaultValue: "Running")
        case .paused: return L10n.string("mobile.cloud.status.paused", defaultValue: "Paused")
        case .provisioning: return L10n.string("mobile.cloud.status.provisioning", defaultValue: "Starting")
        case .failed: return L10n.string("mobile.cloud.status.failed", defaultValue: "Failed")
        // Destroyed machines are filtered out before they reach a screen; a
        // state this build does not know yet shows the server's own word.
        case .destroyed, .unknown: return machine.status
        }
    }

    private var statusColor: Color {
        switch machine.lifecycle {
        case .running: return .green
        case .failed: return .red
        default: return .secondary
        }
    }

    /// The control plane writes its own user-facing reason for an attach it
    /// refused; anything else gets the local copy for its kind.
    private func connectionReason(_ failure: CloudSessionFailure) -> String {
        guard case .controlPlane = failure.kind else { return failure.localizedMessage }
        return failure.action ?? failure.localizedMessage
    }

    private func failureText(_ failure: CloudMachineActionFailure) -> String {
        let format: String
        switch failure.action {
        case .pause: format = L10n.string("mobile.cloud.action.pauseFailedFormat", defaultValue: "Couldn't pause: %@")
        case .resume: format = L10n.string("mobile.cloud.action.resumeFailedFormat", defaultValue: "Couldn't resume: %@")
        case .restart: format = L10n.string("mobile.cloud.action.restartFailedFormat", defaultValue: "Couldn't restart: %@")
        case .delete: format = L10n.string("mobile.cloud.action.deleteFailedFormat", defaultValue: "Couldn't delete: %@")
        }
        return String(format: format, failure.failure.action ?? failure.failure.localizedMessage)
    }
}

/// A failure row with a localized message and a Retry button.
struct CloudFailureRow: View {
    let failure: CloudSessionFailure
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(failure.localizedMessage)
                .foregroundStyle(.secondary)
            if let action = failure.action, !action.isEmpty {
                Text(action)
                    .font(.footnote)
                    .foregroundStyle(.primary)
            }
            #if DEBUG
            // The underlying error is useful during development, but is not
            // stable or user-facing release copy.
            Text(failure.detail)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .accessibilityIdentifier("CloudFailureDetail")
            #endif
            Button(L10n.string("mobile.cloud.retry", defaultValue: "Retry"), action: retry)
                .buttonStyle(.bordered)
        }
        .accessibilityIdentifier("CloudFailureRow")
    }
}

/// Localized copy for each failure kind.
extension CloudSessionFailure {
    /// The Cloud service refused the action for a plan limit (HTTP 402):
    /// no create credits, the active machine limit, or a paid-only resume.
    var isPlanLimit: Bool {
        if case .controlPlane(status: 402) = kind { return true }
        return false
    }

    var localizedMessage: String {
        switch kind {
        case .signedOut:
            return L10n.string("mobile.cloud.error.signedOut", defaultValue: "Your session expired. Sign in again to reach your cloud machines.")
        case .controlPlane:
            return L10n.string("mobile.cloud.error.controlPlane", defaultValue: "The cloud service could not be reached. Try again in a moment.")
        case .tunnel:
            return L10n.string("mobile.cloud.error.tunnel", defaultValue: "Could not join your private network. Check your connection and try again.")
        case .link:
            return L10n.string("mobile.cloud.error.link", defaultValue: "Could not reach this machine's terminal service.")
        case .identity:
            return L10n.string("mobile.cloud.error.identity", defaultValue: "This device is locked. Unlock it and try again.")
        case .other:
            return L10n.string("mobile.cloud.error.other", defaultValue: "Something went wrong. Try again.")
        }
    }
}
#endif
