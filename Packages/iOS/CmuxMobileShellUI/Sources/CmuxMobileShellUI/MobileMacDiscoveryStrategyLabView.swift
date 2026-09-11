#if os(iOS)
import CmuxMobileShellModel
import SwiftUI

#if DEBUG
/// DEBUG-only selector for exercising each first-pair route source.
struct MobileMacDiscoveryStrategyLabView: View {
    @AppStorage(MobileMacDiscoveryStrategyStore.strategyKey)
    private var rawStrategy = MobileMacDiscoveryStrategy.automatic.rawValue

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

            Section("Selected path") {
                Label(strategy.detail, systemImage: strategy == .qr ? "qrcode" : "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Path Discovery Lab")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("MobileMacDiscoveryStrategyLab")
    }
}
#endif
#endif
