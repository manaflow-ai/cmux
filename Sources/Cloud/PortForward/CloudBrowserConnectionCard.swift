import SwiftUI

/// Inline progress and retry UI for a private Cloud browser connection.
struct CloudBrowserConnectionCard: View {
    let address: String
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
                if let onRetry {
                    Button(String(localized: "browser.error.reload", defaultValue: "Reload"), action: onRetry)
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("CloudBrowserRetryButton")
                }
                if message == nil {
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
