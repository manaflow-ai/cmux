#if os(iOS)
import CmuxMobileShellModel
import SwiftUI

#if DEBUG
/// DEBUG-only selector for exercising each first-pair route source.
struct MobileMacDiscoveryStrategyLabView: View {
    @AppStorage(MobileMacDiscoveryStrategyStore.strategyKey)
    private var rawStrategy = MobileMacDiscoveryStrategy.automatic.rawValue
    @State private var pathUI = MobileTailscalePathUIVariant.perPath
    @State private var enabledPaths: Set<String> = []
    @State private var showsPathDetails = false
    @State private var showsEnableConfirmation = false

    private let suggestedPaths = [
        SuggestedTailscalePath(
            id: "ipv4",
            title: "Tailscale IPv4",
            address: "100.101.22.14:49152",
            detail: "Available on this network"
        ),
        SuggestedTailscalePath(
            id: "ipv6",
            title: "Tailscale IPv6",
            address: "fd7a:115c:a1e0::42:49152",
            detail: "Available on this network"
        ),
    ]

    private var strategy: MobileMacDiscoveryStrategy {
        MobileMacDiscoveryStrategy(rawValue: rawStrategy) ?? .automatic
    }

    var body: some View {
        Form {
            Section {
                Picker("Discovery strategy", selection: $rawStrategy) {
                    ForEach(MobileMacDiscoveryStrategy.allCases) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
                .pickerStyle(.inline)
            } header: {
                Text("First-pair route")
            } footer: {
                Text("The next Computers refresh uses this strategy. QR / Manual intentionally disables live broker candidates.")
            }

            Section {
                Picker("Computer detail UI", selection: $pathUI) {
                    ForEach(MobileTailscalePathUIVariant.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.inline)
            } header: {
                Text("Tailscale enablement UI")
            } footer: {
                Text("All three variants use the same enablement state. Suggested paths start disabled.")
            }

            Section {
                switch pathUI {
                case .perPath:
                    perPathEnablement
                case .grouped:
                    groupedEnablement
                case .confirmation:
                    confirmationEnablement
                }
            } header: {
                Text("Computer Details preview")
            }

            Section("Selected path") {
                Label(strategy.detail, systemImage: strategy == .qr ? "qrcode" : "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Path Discovery Lab")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("MobileMacDiscoveryStrategyLab")
    }

    private var enabledCount: Int {
        suggestedPaths.reduce(into: 0) { count, path in
            count += enabledPaths.contains(path.id) ? 1 : 0
        }
    }

    private var perPathEnablement: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tailscale Only")
                .font(.headline)
            Text("Suggested paths")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ForEach(suggestedPaths) { path in
                pathToggle(path)
            }
            Text("Enable one or more paths. cmux will validate the active Tailscale interface before dialing.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("MobileTailscalePathsPerPath")
    }

    private var groupedEnablement: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Use suggested Tailscale paths", isOn: Binding(
                get: { enabledCount > 0 },
                set: { isEnabled in
                    enabledPaths = isEnabled ? Set(suggestedPaths.map(\.id)) : []
                }
            ))
            .accessibilityIdentifier("MobileTailscalePathsGroupedToggle")

            Text(enabledCount == 0
                ? "2 paths detected, currently disabled"
                : "\(enabledCount) of \(suggestedPaths.count) paths enabled")
                .font(.footnote)
                .foregroundStyle(.secondary)

            DisclosureGroup("Show paths", isExpanded: $showsPathDetails) {
                ForEach(suggestedPaths) { path in
                    pathToggle(path)
                }
            }
            .accessibilityIdentifier("MobileTailscalePathsDetails")

            Text("The group switch enables all suggestions. Use Show paths to control IPv4 and IPv6 separately.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("MobileTailscalePathsGrouped")
    }

    private var confirmationEnablement: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Suggested paths found")
                .font(.headline)
            Text("2 Tailscale paths are available. They remain disabled until you approve them.")
                .foregroundStyle(.secondary)
            ForEach(suggestedPaths) { path in
                HStack(spacing: 10) {
                    Image(systemName: enabledPaths.contains(path.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(enabledPaths.contains(path.id) ? Color.accentColor : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(path.title)
                        Text(path.address)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    enabledPaths.formSymmetricDifference([path.id])
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(path.title)
                .accessibilityValue(enabledPaths.contains(path.id) ? "Enabled" : "Disabled")
                .accessibilityIdentifier("MobileTailscalePathsConfirmation-\(path.id)")
            }
            Button("Enable suggested paths") {
                showsEnableConfirmation = true
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("MobileTailscalePathsEnableSuggested")
            Button("Keep disabled", role: .cancel) {
                enabledPaths.removeAll()
            }
            .accessibilityIdentifier("MobileTailscalePathsKeepDisabled")
            Text("Approval enables the selected suggestions. Transport still checks the live Tailscale path before use.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .confirmationDialog(
            "Enable Tailscale paths?",
            isPresented: $showsEnableConfirmation,
            titleVisibility: .visible
        ) {
            Button("Enable") {
                enabledPaths = Set(suggestedPaths.map(\.id))
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("cmux will use these paths only after the active Tailscale interface and route identity are verified.")
        }
        .accessibilityIdentifier("MobileTailscalePathsConfirmation")
    }

    private func pathToggle(_ path: SuggestedTailscalePath) -> some View {
        Toggle(isOn: Binding(
            get: { enabledPaths.contains(path.id) },
            set: { isEnabled in
                if isEnabled {
                    enabledPaths.insert(path.id)
                } else {
                    enabledPaths.remove(path.id)
                }
            }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(path.title)
                Text(path.address)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                Text(path.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("MobileTailscalePathToggle-\(path.id)")
    }
}

private struct SuggestedTailscalePath: Identifiable {
    let id: String
    let title: String
    let address: String
    let detail: String
}

private enum MobileTailscalePathUIVariant: String, CaseIterable, Identifiable {
    case perPath
    case grouped
    case confirmation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .perPath: "Per-path toggles"
        case .grouped: "Grouped + details"
        case .confirmation: "Confirm first"
        }
    }
}
#endif
#endif
