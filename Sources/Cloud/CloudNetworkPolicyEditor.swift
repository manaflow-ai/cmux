import CmuxFoundation
import SwiftUI

/// The outbound network controls, embedded in the New Machine sheet and the
/// Network sheet: a mode picker, and in Allowlist mode the presets, domains,
/// IP ranges, and DNS switch behind a disclosure so the sheet stays compact.
struct CloudNetworkPolicyEditor: View {
    @Bindable var model: CloudNetworkPolicyEditorModel
    /// Starts expanded in the Network sheet, where the lists are the point.
    @State private var detailsExpanded: Bool

    init(model: CloudNetworkPolicyEditorModel, detailsInitiallyExpanded: Bool = false) {
        self.model = model
        _detailsExpanded = State(initialValue: detailsInitiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(String(localized: "cloud.network.mode.label", defaultValue: "Outbound access"), selection: $model.mode) {
                ForEach(CloudNetworkPolicyMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("CloudNetworkPolicyEditor.mode")

            Text(model.mode.explanation)
                .cmuxFont(size: 11)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("CloudNetworkPolicyEditor.modeExplanation")

            if model.showsAllowlistDetails {
                DisclosureGroup(isExpanded: $detailsExpanded) {
                    allowlistDetails
                        .padding(.top, 6)
                } label: {
                    Text(allowlistSummary)
                        .cmuxFont(size: 12, weight: .medium)
                }
                .accessibilityIdentifier("CloudNetworkPolicyEditor.allowlist")
            }

            if let note = model.requiredDomainsNote {
                Text(note)
                    .cmuxFont(size: 11)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = model.inputError {
                Text(error)
                    .cmuxFont(size: 11)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("CloudNetworkPolicyEditor.inputError")
            }
        }
    }

    /// "Presets: 2 · Domains: 3 · IP ranges: 1". Label-and-number form needs
    /// no plural rules; the numbers are formatted for the locale.
    private var allowlistSummary: String {
        let format = String(
            localized: "cloud.network.allowlist.summary",
            defaultValue: "Presets: %1$@ · Domains: %2$@ · IP ranges: %3$@"
        )
        let counts = [model.policy.presets.count, model.policy.domains.count, model.policy.ranges.count]
            .map { NumberFormatter.localizedString(from: NSNumber(value: $0), number: .decimal) }
        return String(format: format, counts[0], counts[1], counts[2])
    }

    private var allowlistDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.presets.isEmpty {
                section(String(localized: "cloud.network.presets.label", defaultValue: "Quick add")) {
                    CloudNetworkPresetToggles(
                        presets: model.presets,
                        isEnabled: { model.isPresetEnabled($0) },
                        setEnabled: { id, enabled in model.setPreset(id, enabled: enabled) }
                    )
                }
            }

            section(String(localized: "cloud.network.domains.label", defaultValue: "Domains (HTTPS)")) {
                ForEach(model.policy.domains, id: \.self) { domain in
                    CloudNetworkEntryRow(text: domain) { model.removeDomain(domain) }
                }
                HStack(spacing: 6) {
                    TextField(
                        String(localized: "cloud.network.domains.placeholder", defaultValue: "e.g. api.example.com"),
                        text: $model.domainDraft
                    )
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.addDomain() }
                    .accessibilityIdentifier("CloudNetworkPolicyEditor.domainField")
                    Button(String(localized: "cloud.network.add", defaultValue: "Add")) { model.addDomain() }
                        .controlSize(.small)
                        .accessibilityIdentifier("CloudNetworkPolicyEditor.addDomain")
                }
            }

            section(String(localized: "cloud.network.ranges.label", defaultValue: "IP ranges")) {
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
                    .frame(width: 64)
                    .onSubmit { model.addRange() }
                    Picker(String(localized: "cloud.network.ranges.protocol", defaultValue: "Protocol"), selection: $model.protocolDraft) {
                        ForEach(CloudNetworkRangeProtocol.allCases, id: \.self) { transport in
                            Text(transport.rawValue.uppercased()).tag(transport)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 70)
                    .disabled(model.portDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button(String(localized: "cloud.network.add", defaultValue: "Add")) { model.addRange() }
                        .controlSize(.small)
                        .accessibilityIdentifier("CloudNetworkPolicyEditor.addRange")
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Toggle(String(localized: "cloud.network.dns.label", defaultValue: "Allow DNS lookups"), isOn: $model.allowDns)
                    .accessibilityIdentifier("CloudNetworkPolicyEditor.dns")
                Text(String(
                    localized: "cloud.network.dns.note",
                    defaultValue: "Listed domains work without DNS. Open DNS lets tools resolve names for IP ranges, but DNS is also an outbound channel."
                ))
                .cmuxFont(size: 11)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .cmuxFont(size: 11, weight: .semibold)
                .foregroundStyle(.secondary)
            content()
        }
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

/// Preset checkboxes in two columns. Closures only, for the same reason.
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
                        Toggle(preset.label, isOn: Binding(
                            get: { isEnabled(preset.id) },
                            set: { setEnabled(preset.id, $0) }
                        ))
                        .toggleStyle(.checkbox)
                        .help(preset.domains.joined(separator: ", "))
                        .accessibilityIdentifier("CloudNetworkPolicyEditor.preset.\(preset.id)")
                    }
                }
            }
        }
    }
}
