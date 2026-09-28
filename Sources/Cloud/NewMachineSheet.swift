import CmuxCloud
import CmuxFoundation
import SwiftUI

/// The New Machine sheet: one image size and what the plan allows. Every
/// machine is the same devbox with a screen, so there is nothing else to ask.
/// Presented by ``NewMachineSheetPresenter`` as a window sheet on the main
/// window. Create closes it at once; the machine coming up is shown by the
/// Machines panel, not here, so the sheet never holds the window.
struct NewMachineSheet: View {
    @Bindable var model: NewMachineModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if hasSettingsRows {
                settingsGrid
            }
            if let note = model.freeAccessNoteText {
                Text(note)
                    .cmuxFont(size: 11)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let errorText = model.errorText {
                errorBox(errorText)
            }
            footer
        }
        .padding(20)
        .frame(width: 500)
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

    /// New Machine shows its description as the title's tooltip; Base has no
    /// settings rows, so its description stays visible because it is the
    /// only thing that says what Base is.
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
        model.supportsSize || model.hasNoAllowedMemoryOptions || model.supportsNetworkPolicy || model.supportsAgentUpdates
    }

    /// One label column, one control column, like a System Settings pane.
    private var settingsGrid: some View {
        Grid(alignment: Alignment(horizontal: .leading, vertical: .firstTextBaseline), horizontalSpacing: 12, verticalSpacing: 14) {
            if model.supportsSize || model.hasNoAllowedMemoryOptions {
                GridRow {
                    rowLabel(String(localized: "machines.new.row.size", defaultValue: "Size"))
                    sizeControl
                }
            }
            if model.supportsNetworkPolicy {
                GridRow {
                    rowLabel(String(localized: "cloud.network.section.label", defaultValue: "Network"))
                    networkControl
                }
            }
            if model.supportsAgentUpdates {
                GridRow {
                    rowLabel(String(localized: "machines.new.row.agents", defaultValue: "Coding agents"))
                    agentUpdatesControl
                }
            }
        }
    }

    private func rowLabel(_ title: String) -> some View {
        Text(title)
            .cmuxFont(size: 13)
            .gridColumnAlignment(.trailing)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var sizeControl: some View {
        if model.hasNoAllowedMemoryOptions {
            Text(String(localized: "machines.new.size.noneAllowed", defaultValue: "No machine size is available for this plan. Close this dialog and reopen it to refresh your plan."))
                .cmuxFont(size: 12)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("NewMachineSheet.size.noneAllowed")
        } else if let selectedSize = model.selectedSize {
            Menu {
                ForEach(model.memoryOptions, id: \.self) { memoryMb in
                    if let size = MachineSizeOption(memoryMb: memoryMb) {
                        Button(size.menuTitle) { model.selectSize(memoryMb) }
                    }
                }
                ForEach(model.lockedMemoryOptions, id: \.self) { memoryMb in
                    if let size = MachineSizeOption(memoryMb: memoryMb) {
                        Button { model.selectSize(memoryMb) } label: {
                            Label(model.lockedSizeMenuTitle(size), systemImage: "lock.fill")
                        }
                        .disabled(model.upgradePlan(for: memoryMb) == nil)
                        .accessibilityIdentifier("NewMachineSheet.size.locked.\(memoryMb)")
                    }
                }
            } label: {
                Text(selectedSize.menuTitle)
            }
            .fixedSize()
            .help(String(localized: "machines.new.size.help", defaultValue: "Choose the memory and disk profile for this machine."))
            .accessibilityIdentifier("NewMachineSheet.size")
            .accessibilityLabel(String(localized: "machines.new.size.accessibilityLabel", defaultValue: "RAM size"))
            .accessibilityValue(selectedSize.menuTitle)
        }
    }

    @ViewBuilder
    private var networkControl: some View {
        Group {
            switch model.networkAvailability {
            case .loading:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(String(localized: "cloud.network.loading", defaultValue: "Loading network options…"))
                        .cmuxFont(size: 12)
                        .foregroundStyle(.secondary)
                    CloudSecurityExplainer()
                }
            case .unavailable:
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(String(
                        localized: "cloud.network.unavailable",
                        defaultValue: "Network options could not be loaded. The machine gets full internet access; change it later with Network… in the machine menu."
                    ))
                    .cmuxFont(size: 12)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    CloudSecurityExplainer()
                }
            case .available:
                CloudNetworkPolicyEditor(model: model.network)
            }
        }
        .accessibilityIdentifier("NewMachineSheet.network")
    }

    private var agentUpdatesControl: some View {
        CloudCheckboxRow(
            title: String(localized: "machines.new.agentUpdates.short", defaultValue: "Keep up to date"),
            accessibilityTitle: String(localized: "machines.new.agentUpdates.label", defaultValue: "Keep coding agents up to date"),
            isOn: $model.keepsAgentsUpdated
        ) {
            if let note = model.agentUpdatesNetworkNote {
                Text(note)
                    .cmuxFont(size: 11)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("NewMachineSheet.agentUpdates.networkNote")
            }
        }
        .help(String(
            localized: "machines.new.agentUpdates.help",
            defaultValue: "Updates Claude Code, Codex, OpenCode, and Pi to the newest release when you connect, at most once a day. A new release installs only after it has been public for 3 days."
        ))
        .accessibilityIdentifier("NewMachineSheet.agentUpdates")
    }

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

    /// Plan usage and the upgrade for locked sizes share the row with the
    /// buttons; the longer explanations are tooltips.
    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let meter = model.planMeterText {
                Text(meter)
                    .cmuxFont(size: 11)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
        .padding(.top, 4)
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

#if DEBUG
/// Plain SwiftUI alternatives for reviewing the size control without a web mockup.
/// These views are preview-only. The sheet uses the first variation: the native menu.
private struct NewMachinePickerVariationsPreview: View {
    @State private var selectedMemoryMb = 8192
    var viewportHeight: CGFloat = 820

    private static let sizes = NewMachineModel.memoryOptionsMb
        .compactMap { MachineSizeOption(memoryMb: $0) }

    private var selectedSize: MachineSizeOption {
        MachineSizeOption(memoryMb: selectedMemoryMb) ?? Self.sizes[1]
    }

    private var selectedIndex: Int {
        Self.sizes.firstIndex(where: { $0.memoryMb == selectedMemoryMb }) ?? 0
    }

    private var selectedIndexBinding: Binding<Int> {
        Binding(
            get: { selectedIndex },
            set: { selectedMemoryMb = Self.sizes[$0].memoryMb }
        )
    }

    private var selectedIndexDoubleBinding: Binding<Double> {
        Binding(
            get: { Double(selectedIndex) },
            set: {
                let index = min(max(Int($0.rounded()), 0), Self.sizes.count - 1)
                selectedMemoryMb = Self.sizes[index].memoryMb
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(String(localized: "machines.new.size.label", defaultValue: "Machine size"))
                    .font(.headline)
                Text(String(
                    localized: "machines.new.size.help",
                    defaultValue: "Choose the memory and disk profile for this machine."
                ))
                .foregroundStyle(.secondary)

                variation(1) {
                    Picker(selection: $selectedMemoryMb) {
                        sizeOptions
                    } label: {
                        Text(selectedSize.menuTitle)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                variation(2) {
                    Picker(selection: $selectedMemoryMb) {
                        ForEach(Self.sizes, id: \.memoryMb) { size in
                            Text(size.title).tag(size.memoryMb)
                        }
                    } label: {
                        Text(selectedSize.menuTitle)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                variation(3) {
                    Picker(selection: $selectedMemoryMb) {
                        sizeOptions
                    } label: {
                        Text(selectedSize.menuTitle)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }

                variation(4) {
                    Stepper(value: selectedIndexBinding, in: 0...(Self.sizes.count - 1)) {
                        Text(selectedSize.menuTitle)
                    }
                }

                variation(5) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(selectedSize.menuTitle)
                        Slider(value: selectedIndexDoubleBinding, in: 0...Double(Self.sizes.count - 1), step: 1)
                    }
                }

                variation(6) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Self.sizes, id: \.memoryMb) { size in
                            Button {
                                selectedMemoryMb = size.memoryMb
                            } label: {
                                HStack {
                                    Text(size.menuTitle)
                                    Spacer()
                                    if size.memoryMb == selectedMemoryMb {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                variation(7) {
                    DisclosureGroup(selectedSize.menuTitle) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Self.sizes, id: \.memoryMb) { size in
                                Button(size.menuTitle) {
                                    selectedMemoryMb = size.memoryMb
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.top, 4)
                    }
                }

                variation(8) {
                    Menu {
                        ForEach(Self.sizes, id: \.memoryMb) { size in
                            Button(size.menuTitle) {
                                selectedMemoryMb = size.memoryMb
                            }
                        }
                    } label: {
                        Text(selectedSize.menuTitle)
                    }
                }

                variation(9) {
                    Picker(selection: $selectedMemoryMb) {
                        sizeOptions
                    } label: {
                        Text(String(localized: "machines.new.size.label", defaultValue: "Machine size"))
                    }
                }

                variation(10) {
                    HStack(spacing: 8) {
                        Button {
                            selectedMemoryMb = Self.sizes[max(selectedIndex - 1, 0)].memoryMb
                        } label: {
                            Image(systemName: "minus")
                        }
                        .buttonStyle(.bordered)
                        Text(selectedSize.menuTitle)
                        Button {
                            selectedMemoryMb = Self.sizes[min(selectedIndex + 1, Self.sizes.count - 1)].memoryMb
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .frame(width: 588, alignment: .leading)
            .padding()
        }
        .frame(width: 620, height: viewportHeight)
    }

    @ViewBuilder
    private var sizeOptions: some View {
        ForEach(Self.sizes, id: \.memoryMb) { size in
            Text(size.menuTitle).tag(size.memoryMb)
        }
    }

    @ViewBuilder
    private func variation<Content: View>(
        _ number: Int,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(format: "%02d", number))
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
            Divider()
        }
    }
}

private struct NewMachinePickerVariationsPreview_Previews: PreviewProvider {
    static var previews: some View {
        NewMachinePickerVariationsPreview()
    }
}
#endif
