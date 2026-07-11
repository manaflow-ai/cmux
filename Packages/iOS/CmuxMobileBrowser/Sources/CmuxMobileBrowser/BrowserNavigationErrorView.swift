#if canImport(UIKit)
import CmuxMobileSupport
import SwiftUI

/// Recoverable navigation failure content shown over the browser page.
struct BrowserNavigationErrorView: View {
    let failedURL: URL?
    let errorDescription: String
    let retry: () -> Void
    let goBack: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)

                Text(L10n.string("mobile.browser.error.title", defaultValue: "Page Couldn’t Load"))
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)

                if let failedURL {
                    Text(failedURL.absoluteString)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .accessibilityLabel(
                            L10n.string("mobile.browser.error.destination", defaultValue: "Failed destination")
                        )
                }

                Text(errorDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                HStack(spacing: 12) {
                    Button(action: goBack) {
                        Text(L10n.string("mobile.browser.back", defaultValue: "Back"))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("MobileBrowserErrorBackButton")

                    Button(action: retry) {
                        Text(L10n.string("mobile.browser.error.retry", defaultValue: "Try Again"))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(failedURL == nil)
                    .accessibilityIdentifier("MobileBrowserErrorRetryButton")
                }
            }
            .frame(maxWidth: 420)
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MobileBrowserNavigationError")
    }
}
#endif
