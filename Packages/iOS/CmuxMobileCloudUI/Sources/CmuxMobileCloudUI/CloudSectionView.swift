#if os(iOS)
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
    @State private var isCreateSheetPresented = false

    /// Creates the section over a session controller.
    public init(controller: CloudSessionController) {
        _controller = State(initialValue: controller)
    }

    public var body: some View {
        List {
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
                Section {
                    Text(L10n.string("mobile.cloud.empty.create", defaultValue: "No Cloud machines yet. Create one below."))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("CloudMachinesEmpty")
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
                            resume: { Task { await controller.resumeMachine(machine) } },
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
                isCreateSheetPresented = true
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
/// billing checks. The phone mirrors the Mac sheet's size, outbound network,
/// and agent update settings, then sends the same create fields.
struct CloudCreateMachineSheet: View {
    let controller: CloudSessionController
    let availableKinds: Set<CloudMachineKind>?
    let limits: CloudMachineLimits?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var selectedMemoryMb: Int
    @State private var networkCatalog: CloudNetworkPresetCatalog?
    @State private var networkPolicy: CloudNetworkPolicy
    @State private var networkCatalogLoaded = false
    @State private var networkPolicyError: String?
    @State private var domainDraft = ""
    @State private var rangeDraft = ""
    @State private var portDraft = ""
    @State private var rangeProtocol: CloudNetworkRangeProtocol = .tcp
    @State private var showsNetworkInfo = false
    @State private var showsAgentInfo = false
    @AppStorage("mobile.cloud.create.keepsAgentsUpdated") private var keepsAgentsUpdated = true

    init(
        controller: CloudSessionController,
        availableKinds: Set<CloudMachineKind>?,
        limits: CloudMachineLimits?
    ) {
        self.controller = controller
        self.availableKinds = availableKinds
        self.limits = limits
        _selectedMemoryMb = State(initialValue: Self.defaultMemoryMb(for: limits))
        let catalog = controller.networkPolicyCatalog
        _networkCatalog = State(initialValue: catalog)
        _networkPolicy = State(initialValue: catalog?.defaultPolicy ?? .default)
    }

    var body: some View {
        NavigationStack {
            Form {
                descriptionSection
                sizeSection
                networkSection
                agentUpdatesSection
                usageSection
                actionSection
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
        .task {
            guard !networkCatalogLoaded else { return }
            let hadCatalog = networkCatalog != nil
            await controller.refreshNetworkPolicyCatalog()
            networkCatalog = controller.networkPolicyCatalog
            if !hadCatalog, let networkCatalog {
                networkPolicy = networkCatalog.defaultPolicy
            }
            networkCatalogLoaded = true
        }
        .sheet(isPresented: $showsNetworkInfo) {
            CloudNetworkInfoSheet()
        }
        .sheet(isPresented: $showsAgentInfo) {
            CloudAgentUpdatesInfoSheet()
        }
        .presentationDetents([.medium, .large])
    }

    private static let pricingURL = URL(string: "https://cmux.com/pricing")!
    private static let fallbackMemoryMb = 8192

    private var descriptionSection: some View {
        Section {
            Text(L10n.string(
                "mobile.cloud.create.description",
                defaultValue: "A cloud computer with devtools and coding agents preinstalled. Its home directory is reset when the machine is recreated."
            ))
            .font(.body)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sizeSection: some View {
        Section {
            Menu {
                ForEach(availableMemoryOptions, id: \.self) { memoryMb in
                    Button(sizeMenuTitle(memoryMb)) {
                        selectedMemoryMb = memoryMb
                    }
                }
                ForEach(lockedMemoryOptions, id: \.self) { memoryMb in
                    Button {
                        openUpgradePage(planID: upgradePlanID(for: memoryMb))
                    } label: {
                        Label(lockedSizeMenuTitle(memoryMb), systemImage: "lock.fill")
                    }
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
                    if let upgradeActionTitle {
                        Button(upgradeActionTitle) {
                            openUpgradePage(planID: highestLockedMemoryUpgradePlanID)
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                        .font(.footnote.weight(.semibold))
                        .accessibilityIdentifier("CloudCreateMachineUpgrade")
                    }
                }
            }
        } header: {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.string("mobile.cloud.create.size.label", defaultValue: "Machine size"))
                Text(L10n.string(
                    "mobile.cloud.create.size.help",
                    defaultValue: "Choose the CPU, memory, and disk profile for this machine."
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var networkSection: some View {
        Section {
            if let networkCatalog {
                HStack {
                    Picker(
                        L10n.string("mobile.cloud.network.access", defaultValue: "Outbound access"),
                        selection: Binding(
                            get: { networkPolicy.mode },
                            set: {
                                networkPolicy.setMode($0)
                                networkPolicyError = nil
                            }
                        )
                    ) {
                        ForEach(CloudNetworkPolicyMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .accessibilityIdentifier("CloudCreateMachineNetworkMode")
                    Button {
                        showsNetworkInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.string(
                        "mobile.cloud.network.info",
                        defaultValue: "How network access works"
                    ))
                    .accessibilityIdentifier("CloudCreateMachineNetworkInfo")
                }
                .contentShape(Rectangle())

                Text(networkPolicy.mode.explanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if networkPolicy.mode == .allowlist {
                    allowlistSection(catalog: networkCatalog)
                }
            } else if networkCatalogLoaded {
                Label(
                    L10n.string("mobile.cloud.network.full.compatibility", defaultValue: "Full internet"),
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.secondary)
                Text(L10n.string(
                    "mobile.cloud.network.unavailable",
                    defaultValue: "Network choices are unavailable on this Cloud service. New machines use full internet access."
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(L10n.string("mobile.cloud.network.loading", defaultValue: "Loading network choices"))
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(L10n.string("mobile.cloud.network.section", defaultValue: "Network"))
        }
    }

    @ViewBuilder
    private func allowlistSection(catalog: CloudNetworkPresetCatalog) -> some View {
        if !catalog.presets.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.string("mobile.cloud.network.quickAdd", defaultValue: "Quick add"))
                    .font(.subheadline.weight(.medium))
                ForEach(catalog.presets) { preset in
                    Toggle(
                        preset.label,
                        isOn: Binding(
                            get: { networkPolicy.presets.contains(preset.id) },
                            set: { networkPolicy.setPreset(preset.id, enabled: $0) }
                        )
                    )
                    .accessibilityIdentifier("CloudCreateMachineNetworkPreset.\(preset.id)")
                }
            }
        }

        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.string("mobile.cloud.network.domains", defaultValue: "Domains (HTTPS)"))
                .font(.subheadline.weight(.medium))
            ForEach(networkPolicy.domains, id: \.self) { domain in
                networkEntryRow(domain) { networkPolicy.removeDomain(domain) }
            }
            HStack {
                TextField(
                    L10n.string("mobile.cloud.network.domainPlaceholder", defaultValue: "api.example.com"),
                    text: $domainDraft
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                Button(L10n.string("mobile.cloud.network.add", defaultValue: "Add")) {
                    addDomain()
                }
                .disabled(domainDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }

        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.string("mobile.cloud.network.ranges", defaultValue: "IP ranges"))
                .font(.subheadline.weight(.medium))
            ForEach(networkPolicy.ranges, id: \.identityKey) { range in
                networkEntryRow(range.displayText) { networkPolicy.removeRange(range) }
            }
            TextField(
                L10n.string("mobile.cloud.network.rangePlaceholder", defaultValue: "203.0.113.0/24"),
                text: $rangeDraft
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            HStack {
                TextField(
                    L10n.string("mobile.cloud.network.portPlaceholder", defaultValue: "Port"),
                    text: $portDraft
                )
                .keyboardType(.numberPad)
                Picker(
                    L10n.string("mobile.cloud.network.protocol", defaultValue: "Protocol"),
                    selection: $rangeProtocol
                ) {
                    ForEach(CloudNetworkRangeProtocol.allCases, id: \.self) { protocolName in
                        Text(protocolName.rawValue.uppercased()).tag(protocolName)
                    }
                }
                .disabled(portDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(L10n.string("mobile.cloud.network.add", defaultValue: "Add")) {
                    addRange()
                }
                .disabled(rangeDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }

        Toggle(
            L10n.string("mobile.cloud.network.allowDNS", defaultValue: "Allow DNS lookups"),
            isOn: Binding(
                get: { networkPolicy.allowDns },
                set: { networkPolicy.allowDns = $0 }
            )
        )
        .accessibilityIdentifier("CloudCreateMachineNetworkDNS")

        if !catalog.requiredDomains.isEmpty {
            Text(String(
                format: L10n.string(
                    "mobile.cloud.network.required",
                    defaultValue: "cmux always allows: %@."
                ),
                ListFormatter.localizedString(byJoining: catalog.requiredDomains)
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if let networkPolicyError {
            Text(networkPolicyError)
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    private var agentUpdatesSection: some View {
        Section {
            Toggle(
                L10n.string(
                    "mobile.cloud.agentUpdates.label",
                    defaultValue: "Keep coding agents up to date"
                ),
                isOn: $keepsAgentsUpdated
            )
            .accessibilityIdentifier("CloudCreateMachineAgentUpdates")
            HStack {
                Text(keepsAgentsUpdated
                    ? L10n.string("mobile.cloud.agentUpdates.latest", defaultValue: "Uses each tool's latest eligible release.")
                    : L10n.string("mobile.cloud.agentUpdates.image", defaultValue: "Keeps the versions included in the machine image.")
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    showsAgentInfo = true
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.string(
                    "mobile.cloud.agentUpdates.info",
                    defaultValue: "How agent updates work"
                ))
                .accessibilityIdentifier("CloudCreateMachineAgentUpdatesInfo")
            }
            if let blocked = blockedAgentUpdateDomains {
                Label(
                    String(
                        format: L10n.string(
                            "mobile.cloud.agentUpdates.blocked",
                            defaultValue: "Updates need %@, which this network policy blocks."
                        ),
                        blocked.joined(separator: ", ")
                    ),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            }
        } header: {
            Text(L10n.string("mobile.cloud.agentUpdates.section", defaultValue: "Coding agents"))
        }
    }

    @ViewBuilder
    private var usageSection: some View {
        if let machineUsageText {
            Section {
                Text(machineUsageText)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("CloudCreateMachineUsage")
            }
        }
    }

    private var actionSection: some View {
        Section {
            Button {
                Task {
                    let created = await controller.createMachine(options: .init(
                        kind: machineKind,
                        memoryMb: selectedMemoryMb,
                        networkPolicy: requestedNetworkPolicy,
                        agentUpdates: keepsAgentsUpdated ? .latest : nil
                    ))
                    if created != nil { dismiss() }
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
                Text(failure.detail)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("CloudCreateMachineFailure")
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

    private var highestLockedMemoryUpgradePlanID: String? {
        lockedMemoryUpgradePlanIDs.max { upgradePriority($0) < upgradePriority($1) }
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
        let usage: String
        if let maximum = limits.maxActiveMachines {
            usage = String(
                format: L10n.string(
                    "mobile.cloud.create.usage",
                    defaultValue: "%1$d of %2$d machines in use"
                ),
                activeCount,
                maximum
            )
        } else {
            usage = String(
                format: L10n.string(
                    "mobile.cloud.create.usageUnlimited",
                    defaultValue: "%d machines in use"
                ),
                activeCount
            )
        }
        guard limits.freeAccessWindowDays > 0, !isPaidPlan(limits.planID) else { return usage }
        return usage + " · " + String(
            format: L10n.string(
                "mobile.cloud.create.freeWindow",
                defaultValue: "Free for %d days"
            ),
            limits.freeAccessWindowDays
        )
    }

    private func isPaidPlan(_ planID: String?) -> Bool {
        switch planID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "go", "pro", "max", "team", "founders":
            return true
        default:
            return false
        }
    }

    private func sizeMenuTitle(_ memoryMb: Int) -> String {
        let format = L10n.string(
            "mobile.cloud.create.size.menu.vcpu",
            defaultValue: "%1$d vCPU · %2$d GB RAM · %3$d GB disk"
        )
        return String(
            format: format,
            vcpus(for: memoryMb),
            memoryMb / 1024,
            (Self.diskMb(for: memoryMb) ?? memoryMb) / 1024
        )
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

    private func upgradePriority(_ planID: String) -> Int {
        switch normalizedPlanID(planID) {
        case "max": return 2
        case "pro": return 1
        default: return 0
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

    private func vcpus(for memoryMb: Int) -> Int {
        limits?.vcpusByMemoryMb?[String(memoryMb)] ?? max(1, Int(ceil(Double(memoryMb) / 4096)))
    }

    private var blockedAgentUpdateDomains: [String]? {
        guard keepsAgentsUpdated, let networkCatalog else { return nil }
        let blocked = CloudAgentUpdates.latest.blockedDomains(for: networkPolicy, catalog: networkCatalog)
        return blocked.isEmpty ? nil : blocked
    }

    private var requestedNetworkPolicy: CloudNetworkPolicy? {
        guard networkCatalog != nil, networkPolicy != .default else { return nil }
        return networkPolicy
    }

    private func addDomain() {
        do {
            try networkPolicy.addDomain(domainDraft)
            domainDraft = ""
            networkPolicyError = nil
        } catch {
            networkPolicyError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }

    private func addRange() {
        let portText = portDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let port: Int?
        if portText.isEmpty {
            port = nil
        } else if let parsed = Int(portText) {
            port = parsed
        } else {
            networkPolicyError = L10n.string(
                "mobile.cloud.network.invalidPort",
                defaultValue: "The port must be a number from 1 to 65535."
            )
            return
        }
        do {
            try networkPolicy.addRange(CloudNetworkRange(
                cidr: rangeDraft,
                port: port,
                transport: port == nil ? nil : rangeProtocol
            ))
            rangeDraft = ""
            portDraft = ""
            networkPolicyError = nil
        } catch {
            networkPolicyError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }

    private func networkEntryRow(_ text: String, remove: @escaping () -> Void) -> some View {
        HStack {
            Text(text)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Button(role: .destructive, action: remove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(L10n.string("mobile.cloud.network.remove", defaultValue: "Remove"))
        }
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

    private func openUpgradePage(planID: String?) {
        // The mobile app has no native billing checkout surface. Keep the
        // locked size visible and use the same pricing entrypoint as macOS.
        guard let planID, var components = URLComponents(url: Self.pricingURL, resolvingAgainstBaseURL: false) else {
            openURL(Self.pricingURL)
            return
        }
        components.queryItems = [URLQueryItem(name: "plan", value: planID)]
        openURL(components.url ?? Self.pricingURL)
    }
}

/// Explains the outbound network setting with the same concepts as the Mac
/// New Machine modal, using a compact diagram that fits the phone sheet.
struct CloudNetworkInfoSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    CloudNetworkInfoDiagram()

                    Text(L10n.string(
                        "mobile.cloud.network.info.summary",
                        defaultValue: "The network setting controls what a Cloud machine can reach. cmux keeps its own connection available so terminals and workspaces can continue to work."
                    ))
                    .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 14) {
                        CloudNetworkInfoRow(
                            title: L10n.string("mobile.cloud.network.full", defaultValue: "Full internet"),
                            detail: L10n.string(
                                "mobile.cloud.network.full.info",
                                defaultValue: "The machine can reach public addresses."
                            ),
                            systemImage: "globe"
                        )
                        CloudNetworkInfoRow(
                            title: L10n.string("mobile.cloud.network.allowlist", defaultValue: "Allowlist"),
                            detail: L10n.string(
                                "mobile.cloud.network.allowlist.info",
                                defaultValue: "Only the listed domains and IP ranges, plus cmux-required services, are reachable."
                            ),
                            systemImage: "checklist"
                        )
                        CloudNetworkInfoRow(
                            title: L10n.string("mobile.cloud.network.none", defaultValue: "No internet"),
                            detail: L10n.string(
                                "mobile.cloud.network.none.info",
                                defaultValue: "Outbound access is closed except for what cmux itself needs."
                            ),
                            systemImage: "nosign"
                        )
                    }

                    Link(
                        L10n.string("mobile.cloud.network.learnMore", defaultValue: "Learn more about Cloud security"),
                        destination: URL(string: "https://cmux.com/docs/cloud-security")!
                    )
                }
                .padding()
            }
            .navigationTitle(L10n.string(
                "mobile.cloud.network.info.title",
                defaultValue: "How network access works"
            ))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("mobile.cloud.done", defaultValue: "Done")) {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct CloudNetworkInfoDiagram: View {
    var body: some View {
        HStack(spacing: 8) {
            CloudInfoDiagramNode(
                title: L10n.string("mobile.cloud.network.info.phone", defaultValue: "Your phone"),
                systemImage: "iphone"
            )
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
            CloudInfoDiagramNode(
                title: L10n.string("mobile.cloud.network.info.edge", defaultValue: "cmux edge"),
                systemImage: "shield.lefthalf.filled"
            )
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
            CloudInfoDiagramNode(
                title: L10n.string("mobile.cloud.network.info.machine", defaultValue: "Cloud machine"),
                systemImage: "cloud"
            )
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }
}

private struct CloudInfoDiagramNode: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(height: 28)
            Text(title)
                .font(.caption)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct CloudNetworkInfoRow: View {
    let title: String
    let detail: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Explains the agent update choice with a short visual flow and the same
/// update behavior exposed by the Mac New Machine modal.
struct CloudAgentUpdatesInfoSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 10) {
                        CloudInfoDiagramNode(
                            title: L10n.string("mobile.cloud.agentUpdates.info.image", defaultValue: "Machine image"),
                            systemImage: "shippingbox"
                        )
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                        CloudInfoDiagramNode(
                            title: L10n.string("mobile.cloud.agentUpdates.info.update", defaultValue: "Eligible updates"),
                            systemImage: "arrow.down.circle"
                        )
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                        CloudInfoDiagramNode(
                            title: L10n.string("mobile.cloud.agentUpdates.info.agents", defaultValue: "Coding agents"),
                            systemImage: "terminal"
                        )
                    }
                    .frame(maxWidth: .infinity)

                    Text(L10n.string(
                        "mobile.cloud.agentUpdates.info.summary",
                        defaultValue: "When enabled, Cloud checks for each supported coding agent's latest eligible release when you connect, at most once a day. Updates never downgrade a tool."
                    ))
                    .fixedSize(horizontal: false, vertical: true)

                    Label(
                        L10n.string(
                            "mobile.cloud.agentUpdates.info.network",
                            defaultValue: "The selected network policy must allow the update hosts."
                        ),
                        systemImage: "network"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle(L10n.string(
                "mobile.cloud.agentUpdates.info.title",
                defaultValue: "Agent updates"
            ))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("mobile.cloud.done", defaultValue: "Done")) {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// One machine row: its name and a lowercased status line.
struct CloudMachineRow: View {
    let machine: CloudMachine
    /// A pause, resume or delete is running for this machine.
    let isBusy: Bool
    /// The last lifecycle failure, when it hit this machine.
    let failure: CloudMachineActionFailure?
    /// Why the machine's terminal service could not be reached, while it is
    /// running but unreachable. The bridge keeps retrying on its own.
    let connectionFailure: CloudSessionFailure?
    let retryConnection: () -> Void
    let pause: () -> Void
    let resume: () -> Void
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
        return [failure.detail, failure.action ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func failureText(_ failure: CloudMachineActionFailure) -> String {
        let format: String
        switch failure.action {
        case .pause: format = L10n.string("mobile.cloud.action.pauseFailedFormat", defaultValue: "Couldn't pause: %@")
        case .resume: format = L10n.string("mobile.cloud.action.resumeFailedFormat", defaultValue: "Couldn't resume: %@")
        case .delete: format = L10n.string("mobile.cloud.action.deleteFailedFormat", defaultValue: "Couldn't delete: %@")
        }
        return String(format: format, failure.failure.action ?? failure.failure.detail)
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
            // The underlying error, so a dogfooder can report the exact cause.
            Text(failure.detail)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .accessibilityIdentifier("CloudFailureDetail")
            Button(L10n.string("mobile.cloud.retry", defaultValue: "Retry"), action: retry)
                .buttonStyle(.bordered)
        }
        .accessibilityIdentifier("CloudFailureRow")
    }
}

/// Localized copy for each failure kind.
extension CloudSessionFailure {
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
