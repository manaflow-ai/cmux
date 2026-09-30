import CmuxCloud
import CmuxFoundation
import SwiftUI

/// How the New Machine sheet arranges its three settings. Release builds
/// always use ``recommended``; DEBUG builds read ``defaultsKey`` each time the
/// sheet opens so the variants can be compared without a rebuild
/// (`defaults write <bundle id> cloud.newMachine.layoutVariant B`).
enum NewMachineSheetLayout: String, CaseIterable {
    /// Two columns: right-aligned labels, left-aligned controls.
    case grid = "A"
    /// One column: a small caps label above each left-aligned control.
    case stacked = "B"
    /// One sentence of borderless menus: "8 GB RAM · Full internet · Agents update".
    case sentence = "C"
    /// A grouped card like System Settings: label leading, control trailing.
    case grouped = "D"

    static let recommended: Self = .grid
    static let defaultsKey = "cloud.newMachine.layoutVariant"

    static var current: Self {
#if DEBUG
        if let raw = UserDefaults.standard.string(forKey: defaultsKey),
           let layout = Self(rawValue: raw.uppercased()) {
            return layout
        }
#endif
        return recommended
    }

    var width: CGFloat {
        switch self {
        case .grid: return 440
        case .stacked: return 440
        case .sentence: return 480
        case .grouped: return 440
        }
    }
}

/// The New Machine sheet: size, network, agent updates, and what the plan
/// allows, as a few labeled controls. Every explanation is a tooltip or the
/// security popover, so nothing wraps while the sheet opens. Presented by
/// ``NewMachineSheetPresenter`` with its data already loaded; Create closes
/// it at once and the Machines panel shows the machine coming up.
struct NewMachineSheet: View {
    @Bindable var model: NewMachineModel
    let layout: NewMachineSheetLayout
    @State private var allowlistExpanded: Bool
    /// Bumped when a locked size is picked: the selection stays put, so the
    /// pop-up is rebuilt to show the real selection again.
    @State private var sizePickerRevision = 0

    init(model: NewMachineModel, layout: NewMachineSheetLayout = .current, allowlistInitiallyExpanded: Bool = false) {
        self.model = model
        self.layout = layout
        _allowlistExpanded = State(initialValue: allowlistInitiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if hasSettingsRows {
                switch layout {
                case .grid: gridLayout
                case .stacked: stackedLayout
                case .sentence: sentenceLayout
                case .grouped: groupedLayout
                }
            }
            if let errorText = model.errorText {
                errorBox(errorText)
            }
            footer
        }
        .padding(20)
        .frame(width: layout.width)
        .accessibilityIdentifier("NewMachineSheet")
        .confirmationDialog(
            String(format: String(localized: "machines.new.size.locked.upgrade", defaultValue: "Upgrade to %@"), NewMachineModel.planDisplayName(model.selectedUpgradePlanId)),
            isPresented: $model.showsMaxUpgrade,
            titleVisibility: .visible
        ) {
            Button(String(localized: "machines.new.max.checkout", defaultValue: "Continue to checkout")) {
                ProUpgradePresenter.presentCheckout(source: .newMachineSheetMaxUpgrade, plan: model.selectedUpgradePlanId == "pro" ? .pro : .max)
            }
        } message: {
            Text(model.selectedUpgradePlanId == "pro" ? String(localized: "pricing.native.pro.price", defaultValue: "$50") : String(localized: "pricing.native.max.price", defaultValue: "$200"))
            + Text(String(localized: "pricing.native.period.month", defaultValue: "/month"))
        }
    }

    // MARK: Header

    private var subtitle: String {
        model.isBaseSetup
            ? String(
                localized: "machines.new.subtitle.base",
                defaultValue: "Base is your persistent cloud machine. Opening it later reuses this same machine; reset Base to start over."
            )
            : String(
                localized: "machines.new.subtitle",
                defaultValue: "A cloud computer with devtools and coding agents preinstalled. Its home directory is reset when the machine is recreated."
            )
    }

    /// New Machine's description is the title's tooltip. Base has no
    /// settings, so its description stays visible: it is the only thing
    /// that says what Base is.
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.isBaseSetup
                ? String(localized: "machines.new.title.base", defaultValue: "Set Up Base")
                : String(localized: "machines.new.title", defaultValue: "New Machine"))
                .cmuxFont(size: 15, weight: .semibold)
                .help(subtitle)
            if model.isBaseSetup {
                Text(subtitle)
                    .cmuxFont(size: 12)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var hasSettingsRows: Bool {
        showsSizeRow || model.supportsNetworkPolicy || model.supportsAgentUpdates
    }

    private var showsSizeRow: Bool { model.supportsSize || model.hasNoAllowedMemoryOptions }

    private var sizeLabel: String { String(localized: "machines.new.row.size", defaultValue: "Size") }
    private var networkLabel: String { String(localized: "cloud.network.section.label", defaultValue: "Network") }
    private var agentsLabel: String { String(localized: "machines.new.row.agents.short", defaultValue: "Agents") }
    private var agentsTitle: String { String(localized: "machines.new.agentUpdates.label", defaultValue: "Keep coding agents up to date") }
    private var agentsHelp: String { CloudAgentUpdatesExplainer.text }

    // MARK: A. Grid

    private var gridLayout: some View {
        Grid(alignment: Alignment(horizontal: .leading, vertical: .firstTextBaseline), horizontalSpacing: 10, verticalSpacing: 12) {
            if showsSizeRow {
                GridRow {
                    gridLabel(sizeLabel)
                    sizeMenu.fixedSize()
                }
            }
            if model.supportsNetworkPolicy {
                GridRow {
                    gridLabel(networkLabel)
                    HStack(spacing: 6) {
                        networkMenu.fixedSize()
                        CloudSecurityExplainer()
                    }
                }
                allowlistGridRows
            }
            if model.supportsAgentUpdates {
                GridRow {
                    gridLabel(agentsLabel)
                    agentsCheckbox
                }
            }
        }
    }

    /// The Allowlist summary under the network control, and the lists
    /// themselves across both columns so they get the sheet's full width.
    @ViewBuilder
    private var allowlistGridRows: some View {
        if showsAllowlist {
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                allowlistToggle
            }
            if allowlistExpanded {
                GridRow {
                    allowlistDetailsBox.gridCellColumns(2)
                }
            }
        }
        if model.network.inputError != nil {
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                CloudNetworkInputError(model: model.network)
            }
        }
    }

    private func gridLabel(_ title: String) -> some View {
        Text(title)
            .cmuxFont(size: 13)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
            .accessibilityHidden(true)
    }

    // MARK: B. Stacked

    private var stackedLayout: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsSizeRow {
                stackedRow(sizeLabel) { sizeMenu.fixedSize() }
            }
            if model.supportsNetworkPolicy {
                stackedRow(networkLabel) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            networkMenu.fixedSize()
                            CloudSecurityExplainer()
                        }
                        networkExtras
                    }
                }
            }
            if model.supportsAgentUpdates {
                stackedRow(agentsLabel) { agentsCheckbox }
            }
        }
    }

    private func stackedRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .cmuxFont(size: 10, weight: .semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .accessibilityHidden(true)
            content()
        }
    }

    // MARK: C. Sentence

    private var sentenceLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                if showsSizeRow {
                    makeSizeMenu(borderless: true)
                    sentenceDot
                }
                if model.supportsNetworkPolicy {
                    makeNetworkMenu(borderless: true)
                    if model.supportsAgentUpdates { sentenceDot }
                }
                if model.supportsAgentUpdates {
                    agentsMenu
                    agentsNetworkWarning
                    CloudAgentUpdatesExplainer()
                }
                Spacer(minLength: 4)
                if model.supportsNetworkPolicy {
                    CloudSecurityExplainer()
                }
            }
            if model.supportsNetworkPolicy {
                networkExtras
            }
        }
    }

    private var sentenceDot: some View {
        Text(verbatim: "·")
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }

    /// The agent-update choice as a borderless menu whose one item is the
    /// checkmarked setting (a menu item, not a checkbox button).
    private var agentsMenu: some View {
        Menu {
            Button {
                model.keepsAgentsUpdated.toggle()
            } label: {
                if model.keepsAgentsUpdated {
                    Label(agentsTitle, systemImage: "checkmark")
                } else {
                    Text(agentsTitle)
                }
            }
        } label: {
            Text(model.keepsAgentsUpdated
                ? String(localized: "machines.new.agentUpdates.on", defaultValue: "Agents auto-update")
                : String(localized: "machines.new.agentUpdates.off", defaultValue: "Agents pinned"))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(agentsHelp)
        .accessibilityLabel(agentsTitle)
        .accessibilityIdentifier("NewMachineSheet.agentUpdates")
    }

    // MARK: D. Grouped

    private var groupedLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsSizeRow {
                groupedRow(sizeLabel) { sizeMenu.fixedSize() }
            }
            if model.supportsNetworkPolicy {
                if showsSizeRow { groupedDivider }
                groupedRow(networkLabel) {
                    HStack(spacing: 6) {
                        CloudSecurityExplainer()
                        networkMenu.fixedSize()
                    }
                }
                if hasNetworkExtras {
                    networkExtras
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                }
            }
            if model.supportsAgentUpdates {
                if showsSizeRow || model.supportsNetworkPolicy { groupedDivider }
                groupedRow(agentsTitle) {
                    HStack(spacing: 6) {
                        agentsNetworkWarning
                        CloudAgentUpdatesExplainer()
                        Toggle(isOn: $model.keepsAgentsUpdated) { EmptyView() }
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .labelsHidden()
                            .fixedSize()
                            .accessibilityLabel(agentsTitle)
                            .accessibilityIdentifier("NewMachineSheet.agentUpdates")
                    }
                }
                .help(agentsHelp)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func groupedRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title)
                .cmuxFont(size: 13)
                .lineLimit(1)
                .accessibilityHidden(true)
            Spacer(minLength: 8)
            content()
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
    }

    private var groupedDivider: some View {
        Divider().padding(.leading, 12)
    }

    // MARK: Shared controls

    private var sizeMenu: some View { makeSizeMenu(borderless: false) }

    /// The size pop-up: allowed sizes, then the locked ones with the plan
    /// that unlocks them. Picking a locked size asks to upgrade instead.
    @ViewBuilder
    private func makeSizeMenu(borderless: Bool) -> some View {
        if model.hasNoAllowedMemoryOptions {
            Label(
                String(localized: "machines.new.size.noneAllowed.short", defaultValue: "No size available"),
                systemImage: "exclamationmark.triangle.fill"
            )
            .cmuxFont(size: 12)
            .foregroundStyle(.orange)
            .lineLimit(1)
            .help(String(localized: "machines.new.size.noneAllowed", defaultValue: "No machine size is available for this plan. Close this dialog and reopen it to refresh your plan."))
            .accessibilityIdentifier("NewMachineSheet.size.noneAllowed")
        } else if let selectedSize = model.selectedSize, !borderless {
            Picker(selection: Binding(
                get: { model.memoryMb },
                set: { requested in
                    model.selectSize(requested)
                    if model.memoryMb != requested { sizePickerRevision &+= 1 }
                }
            )) {
                ForEach(model.memoryOptions, id: \.self) { memoryMb in
                    if let size = model.sizeOption(memoryMb: memoryMb) {
                        Text(size.menuTitle).tag(memoryMb)
                    }
                }
                if !model.lockedMemoryOptions.isEmpty {
                    Divider()
                }
                ForEach(model.lockedMemoryOptions, id: \.self) { memoryMb in
                    if let size = model.sizeOption(memoryMb: memoryMb) {
                        Label(model.lockedSizeMenuTitle(size), systemImage: "lock.fill")
                            .tag(memoryMb)
                            .accessibilityIdentifier("NewMachineSheet.size.locked.\(memoryMb)")
                    }
                }
            } label: {
                Text(String(localized: "machines.new.size.accessibilityLabel", defaultValue: "RAM size"))
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .id(sizePickerRevision)
            .help(String(localized: "machines.new.size.help", defaultValue: "Choose the memory and disk profile for this machine."))
            .accessibilityIdentifier("NewMachineSheet.size")
            .accessibilityValue(selectedSize.menuTitle)
        } else if let selectedSize = model.selectedSize {
            // The sentence layout's token: a borderless menu with checkmarks.
            Menu {
                ForEach(model.memoryOptions, id: \.self) { memoryMb in
                    if let size = model.sizeOption(memoryMb: memoryMb) {
                        Button { model.selectSize(memoryMb) } label: {
                            if memoryMb == model.memoryMb {
                                Label(size.menuTitle, systemImage: "checkmark")
                            } else {
                                Text(size.menuTitle)
                            }
                        }
                    }
                }
                if !model.lockedMemoryOptions.isEmpty {
                    Divider()
                }
                ForEach(model.lockedMemoryOptions, id: \.self) { memoryMb in
                    if let size = model.sizeOption(memoryMb: memoryMb) {
                        Button { model.selectSize(memoryMb) } label: {
                            Label(model.lockedSizeMenuTitle(size), systemImage: "lock.fill")
                        }
                        .disabled(model.upgradePlan(for: memoryMb) == nil)
                        .accessibilityIdentifier("NewMachineSheet.size.locked.\(memoryMb)")
                    }
                }
            } label: {
                Text(selectedSize.title)
            }
            .help(String(localized: "machines.new.size.help", defaultValue: "Choose the memory and disk profile for this machine."))
            .accessibilityIdentifier("NewMachineSheet.size")
            .accessibilityLabel(String(localized: "machines.new.size.accessibilityLabel", defaultValue: "RAM size"))
            .accessibilityValue(selectedSize.menuTitle)
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var networkMenu: some View { makeNetworkMenu(borderless: false) }

    /// The mode menu once the catalog is known; a spinner or a warning icon
    /// with its explanation as the tooltip otherwise. The cache normally has
    /// the catalog before the sheet opens, so the spinner is rare.
    @ViewBuilder
    private func makeNetworkMenu(borderless: Bool) -> some View {
        switch model.networkAvailability {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .help(String(localized: "cloud.network.loading", defaultValue: "Loading network options…"))
                .accessibilityIdentifier("NewMachineSheet.network")
        case .unavailable:
            Label(
                CloudNetworkPolicyMode.full.title,
                systemImage: "exclamationmark.triangle.fill"
            )
            .cmuxFont(size: 12)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .help(String(
                localized: "cloud.network.unavailable",
                defaultValue: "Network options could not be loaded. The machine gets full internet access; change it later with Network… in the machine menu."
            ))
            .accessibilityIdentifier("NewMachineSheet.network")
        case .available:
            if borderless {
                CloudNetworkModeMenu(model: model.network)
                    .accessibilityIdentifier("NewMachineSheet.network")
            } else {
                CloudNetworkModePicker(model: model.network)
                    .accessibilityIdentifier("NewMachineSheet.network")
            }
        }
    }

    private var showsAllowlist: Bool {
        model.networkAvailability == .available && model.network.showsAllowlistDetails
    }

    private var hasNetworkExtras: Bool {
        showsAllowlist || model.network.inputError != nil
    }

    /// The Allowlist summary, its lists when expanded, and any input error.
    @ViewBuilder
    private var networkExtras: some View {
        if showsAllowlist {
            allowlistToggle
            if allowlistExpanded {
                allowlistDetailsBox
            }
        }
        CloudNetworkInputError(model: model.network)
    }

    /// "Presets: 2 · Domains: 3 · IP ranges: 1" with a disclosure chevron.
    private var allowlistToggle: some View {
        Button {
            allowlistExpanded.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: allowlistExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
                CloudNetworkAllowlistSummary(model: model.network)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(allowlistExpanded ? .isSelected : [])
        .accessibilityIdentifier("CloudNetworkPolicyEditor.allowlist")
    }

    /// The lists, grouped in a quiet box at the sheet's full width.
    private var allowlistDetailsBox: some View {
        CloudNetworkAllowlistDetails(model: model.network)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
    }

    /// A label-less checkbox with a sibling title (see ``CloudCheckboxRow``).
    private var agentsCheckbox: some View {
        HStack(spacing: 6) {
            CloudCheckboxRow(
                title: String(localized: "machines.new.agentUpdates.short", defaultValue: "Keep up to date"),
                accessibilityTitle: agentsTitle,
                isOn: $model.keepsAgentsUpdated
            )
            .help(agentsHelp)
            .accessibilityIdentifier("NewMachineSheet.agentUpdates")
            CloudAgentUpdatesExplainer()
            agentsNetworkWarning
        }
    }

    /// Shown when the chosen network blocks a host the updates download
    /// from (the catalog's `agentUpdateDomains`); the explanation is the tooltip.
    @ViewBuilder
    private var agentsNetworkWarning: some View {
        if let note = model.agentUpdatesNetworkNote {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .help(note)
                .accessibilityLabel(note)
                .accessibilityIdentifier("NewMachineSheet.agentUpdates.networkNote")
        }
    }

    // MARK: Error and footer

    private func errorBox(_ text: String) -> some View {
        ScrollView(.vertical) {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.disabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(maxHeight: 160)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.red.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.red.opacity(0.35), lineWidth: 1)
        )
        .accessibilityIdentifier("NewMachineSheet.error")
        .cloudErrorCopyMenu(text)
    }

    /// Plan usage, the free-plan window and the upgrade for locked sizes
    /// share one line with the buttons; the explanations are tooltips.
    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let meter = model.planMeterText {
                Text(meterText(meter))
                    .cmuxFont(size: 11)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(model.freeAccessNoteText ?? meter)
                    .accessibilityHint(model.freeAccessNoteText ?? "")
                    .accessibilityIdentifier("NewMachineSheet.plan")
            }
            if let note = model.lockedSizesNoteText, let upgradeTitle = model.memoryUpgradeButtonTitle {
                Button(upgradeTitle) {
                    model.selectedUpgradePlanId = model.highestLockedMemoryUpgradePlanId ?? model.memoryUpgradePlanId ?? "max"
                    model.showsMaxUpgrade = true
                }
                .buttonStyle(.link)
                .cmuxFont(size: 11)
                .lineLimit(1)
                .help(note)
                .accessibilityHint(note)
                .accessibilityIdentifier("NewMachineSheet.size.upgrade")
            }
            Spacer(minLength: 8)
            Button(String(localized: "machines.new.cancel", defaultValue: "Cancel")) {
                model.cancel()
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("NewMachineSheet.cancel")
            Button(createTitle) {
                model.create()
            }
            .disabled(model.hasNoAllowedMemoryOptions)
            .keyboardShortcut(.defaultAction)
            .help(model.isBaseSetup
                ? String(localized: "machines.new.background.note.base", defaultValue: "Setup continues in the Machines panel.")
                : String(localized: "machines.new.background.note", defaultValue: "Creation continues in the Machines panel."))
            .accessibilityIdentifier("NewMachineSheet.create")
        }
    }

    /// "1 of 1 machine in use · 7-day access" on the free plan.
    private func meterText(_ meter: String) -> String {
        guard let plan = model.plan, !plan.isPaidPlan, plan.freeAccessWindowDays > 0 else { return meter }
        let format = String(localized: "machines.new.plan.freeWindow.short", defaultValue: "Free for %d days")
        return meter + " · " + String(format: format, plan.freeAccessWindowDays)
    }

    private var createTitle: String {
        if model.errorText != nil {
            return String(localized: "machines.new.retry", defaultValue: "Retry")
        }
        return model.isBaseSetup
            ? String(localized: "machines.new.create.base", defaultValue: "Set Up Base")
            : String(localized: "machines.new.create", defaultValue: "Create")
    }
}
