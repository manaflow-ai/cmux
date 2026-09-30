import SwiftUI

/// Inline progress and retry UI for a private Cloud browser connection.
public struct CloudBrowserConnectionCard: View {
    public init(
        address: String,
        message: String? = nil,
        onRetry: (() -> Void)? = nil,
        isDesktop: Bool = false
    ) {
        self.address = address
        self.message = message
        self.onRetry = onRetry
        self.isDesktop = isDesktop
    }

    public let address: String
    public let message: String?
    public let onRetry: (() -> Void)?
    public var isDesktop: Bool = false

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: isDesktop ? "display" : "network").font(.system(size: 28)).foregroundStyle(.secondary)
                Text(isDesktop
                    ? String(localized: "cloud.display.connectTitle", defaultValue: "Connect to this Cloud display")
                    : String(localized: "cloud.ports.accessTitle", defaultValue: "Connect to this Cloud port"))
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
