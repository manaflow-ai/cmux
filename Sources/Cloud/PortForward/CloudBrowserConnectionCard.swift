import SwiftUI

struct CloudBrowserConnectionCard: View {
    let address: String
    let phase: CloudPortAccessModel.Phase
    let message: String?
    let onRetry: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "network").font(.system(size: 28)).foregroundStyle(.secondary)
                Text(String(localized: "cloud.ports.accessTitle", defaultValue: "Connect to this Cloud port"))
                    .font(.title2.weight(.semibold))
                Text(verbatim: address).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                if let message {
                    Text(message).foregroundStyle(.secondary).textSelection(.enabled)
                }
                HStack {
                    if let onRetry {
                        Button(String(localized: "browser.error.reload", defaultValue: "Reload"), action: onRetry)
                            .buttonStyle(.bordered)
                    }
                }
                if message == nil && (phase == .connecting || phase == .direct || { if case .forwarded = phase { return true }; if case .proxied = phase { return true }; return false }()) {
                    ProgressView(String(localized: "cloud.ports.loading", defaultValue: "Loading Cloud page…"))
                }
            }
            .padding(28)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("CloudBrowserConnectionCard")
    }
}
