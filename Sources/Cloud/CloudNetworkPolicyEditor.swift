import CmuxCloud
import CmuxFoundation
import SwiftUI

/// The Network sheet's editor: the mode menu with the security info button,
/// and in Allowlist mode the lists themselves. The New Machine sheet lays
/// out the same pieces (``CloudNetworkModeMenu``,
/// ``CloudNetworkAllowlistDetails``) inside its own rows.
struct CloudNetworkPolicyEditor: View {
    @Bindable var model: CloudNetworkPolicyEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                CloudNetworkModePicker(model: model)
                    .fixedSize()
                CloudSecurityExplainer()
            }
            if model.showsAllowlistDetails {
                CloudNetworkAllowlistDetails(model: model)
            }
            CloudNetworkInputError(model: model)
        }
    }
}

/// Full internet / Allowlist / No internet as a pop-up that fills the
/// width it is given. What each mode allows is the tooltip, not a caption.
struct CloudNetworkModePicker: View {
    @Bindable var model: CloudNetworkPolicyEditorModel

    var body: some View {
        Picker(selection: $model.mode) {
            ForEach(CloudNetworkPolicyMode.allCases, id: \.self) { mode in
                Text(mode.title).tag(mode)
            }
        } label: {
            Text(String(localized: "cloud.network.mode.label", defaultValue: "Outbound access"))
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .help(model.mode.explanation)
        .accessibilityHint(model.mode.explanation)
        .accessibilityIdentifier("CloudNetworkPolicyEditor.mode")
    }
}

/// The same choice as a borderless menu, for the sentence layout.
struct CloudNetworkModeMenu: View {
    @Bindable var model: CloudNetworkPolicyEditorModel

    var body: some View {
        Menu {
            ForEach(CloudNetworkPolicyMode.allCases, id: \.self) { mode in
                Button {
                    model.mode = mode
                } label: {
                    if mode == model.mode {
                        Label(mode.title, systemImage: "checkmark")
                    } else {
                        Text(mode.title)
                    }
                }
                .help(mode.explanation)
            }
        } label: {
            Text(model.mode.title)
        }
        .help(model.mode.explanation)
        .accessibilityLabel(String(localized: "cloud.network.mode.label", defaultValue: "Outbound access"))
        .accessibilityValue(model.mode.title)
        .accessibilityHint(model.mode.explanation)
        .accessibilityIdentifier("CloudNetworkPolicyEditor.mode")
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

/// "Presets: 2 · Domains: 3 · IP ranges: 1". Label-and-number form needs
/// no plural rules; the numbers are formatted for the locale.
struct CloudNetworkAllowlistSummary: View {
    let model: CloudNetworkPolicyEditorModel

    var body: some View {
        let format = String(
            localized: "cloud.network.allowlist.summary",
            defaultValue: "Presets: %1$@ · Domains: %2$@ · IP ranges: %3$@"
        )
        let counts = [model.policy.presets.count, model.policy.domains.count, model.policy.ranges.count]
            .map { NumberFormatter.localizedString(from: NSNumber(value: $0), number: .decimal) }
        Text(String(format: format, counts[0], counts[1], counts[2]))
            .cmuxFont(size: 12)
            .lineLimit(1)
    }
}

/// The last refused add or toggle, in red; nothing when there is none.
struct CloudNetworkInputError: View {
    let model: CloudNetworkPolicyEditorModel

    var body: some View {
        if let error = model.inputError {
            Text(error)
                .cmuxFont(size: 11)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("CloudNetworkPolicyEditor.inputError")
        }
    }
}

/// The allowlist itself: presets, domains, IP ranges, DNS, and the domains
/// cmux always allows. Small row labels, one line each; the longer notes
/// are tooltips.
struct CloudNetworkAllowlistDetails: View {
    @Bindable var model: CloudNetworkPolicyEditorModel

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 8, verticalSpacing: 8) {
            if !model.presets.isEmpty {
                GridRow {
                    rowLabel(String(localized: "cloud.network.presets.label", defaultValue: "Quick add"))
                    CloudNetworkPresetToggles(
                        presets: model.presets,
                        isEnabled: { model.isPresetEnabled($0) },
                        setEnabled: { id, enabled in model.setPreset(id, enabled: enabled) }
                    )
                }
            }
            GridRow {
                rowLabel(String(localized: "cloud.network.domains.label", defaultValue: "Domains (HTTPS)"))
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.policy.domains, id: \.self) { domain in
                        CloudNetworkEntryRow(text: domain) { model.removeDomain(domain) }
                    }
                    HStack(spacing: 6) {
                        TextField(
                            String(localized: "cloud.network.domains.placeholder", defaultValue: "e.g. api.example.com"),
                            text: $model.domainDraft
                        )
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .onSubmit { model.addDomain() }
                        .accessibilityIdentifier("CloudNetworkPolicyEditor.domainField")
                        Button(String(localized: "cloud.network.add", defaultValue: "Add")) { model.addDomain() }
                            .controlSize(.small)
                            .accessibilityIdentifier("CloudNetworkPolicyEditor.addDomain")
                    }
                }
            }
            GridRow {
                rowLabel(String(localized: "cloud.network.ranges.label", defaultValue: "IP ranges"))
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.policy.ranges, id: \.identityKey) { range in
                        CloudNetworkEntryRow(text: range.displayText) { model.removeRange(range) }
                    }
                    HStack(spacing: 6) {
                        TextField(
                            String(localized: "cloud.network.ranges.placeholder", defaultValue: "e.g. 203.0.113.0/24"),
                            text: $model.rangeDraft
                        )
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.addRange() }
                        .accessibilityIdentifier("CloudNetworkPolicyEditor.rangeField")
                        TextField(
                            String(localized: "cloud.network.ranges.port", defaultValue: "Port"),
                            text: $model.portDraft
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 52)
                        .onSubmit { model.addRange() }
                        Picker(String(localized: "cloud.network.ranges.protocol", defaultValue: "Protocol"), selection: $model.protocolDraft) {
                            ForEach(CloudNetworkRangeProtocol.allCases, id: \.self) { transport in
                                Text(transport.rawValue.uppercased()).tag(transport)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 64)
                        .disabled(model.portDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button(String(localized: "cloud.network.add", defaultValue: "Add")) { model.addRange() }
                            .accessibilityIdentifier("CloudNetworkPolicyEditor.addRange")
                    }
                    .controlSize(.small)
                }
            }
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                VStack(alignment: .leading, spacing: 4) {
                    CloudCheckboxRow(
                        title: String(localized: "cloud.network.dns.label", defaultValue: "Allow DNS lookups"),
                        isOn: $model.allowDns,
                        fontSize: 12
                    )
                    .help(String(
                        localized: "cloud.network.dns.note",
                        defaultValue: "Listed domains work without DNS. Open DNS lets tools resolve names for IP ranges, but DNS is also an outbound channel."
                    ))
                    .accessibilityIdentifier("CloudNetworkPolicyEditor.dns")
                    if let note = model.requiredDomainsNote {
                        Text(note)
                            .cmuxFont(size: 11)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(note)
                            .accessibilityIdentifier("CloudNetworkPolicyEditor.requiredDomains")
                    }
                }
            }
        }
    }

    /// Top-aligned rows; the label drops to the first control's text line.
    private func rowLabel(_ title: String) -> some View {
        Text(title)
            .cmuxFont(size: 11)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.top, 3)
            .gridColumnAlignment(.trailing)
    }
}

/// One domain or range with a remove button. Holds only its text and a
/// closure, never the model (it sits below a `ForEach` boundary).
private struct CloudNetworkEntryRow: View {
    let text: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Button(action: onRemove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "cloud.network.remove", defaultValue: "Remove"))
            .accessibilityLabel(String(localized: "cloud.network.remove", defaultValue: "Remove"))
        }
    }
}

/// Preset checkboxes in two columns; each preset's domains are its tooltip.
/// Closures only, for the same reason.
private struct CloudNetworkPresetToggles: View {
    let presets: [CloudNetworkPreset]
    let isEnabled: (String) -> Bool
    let setEnabled: (String, Bool) -> Void

    var body: some View {
        let rows = stride(from: 0, to: presets.count, by: 2).map { Array(presets[$0..<min($0 + 2, presets.count)]) }
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(rows, id: \.first?.id) { row in
                GridRow {
                    ForEach(row) { preset in
                        CloudCheckboxRow(title: preset.label, isOn: Binding(
                            get: { isEnabled(preset.id) },
                            set: { setEnabled(preset.id, $0) }
                        ), fontSize: 12)
                        .help(preset.domains.joined(separator: ", "))
                        .accessibilityIdentifier("CloudNetworkPolicyEditor.preset.\(preset.id)")
                    }
                }
            }
        }
    }
}
