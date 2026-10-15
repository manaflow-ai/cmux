import AppKit
import CmuxBrowser
import SwiftUI

/// A one-line bar under the address bar saying the tab opened in WebKit
/// because Chromium was unavailable, shown once per run (Chrome's infobar
/// placement: between the toolbar and the page, pushing the page down).
struct BrowserEngineFallbackNoticeBar: View {
    let reason: BrowserEngineUnavailableReason
    let backgroundColor: NSColor
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .lineLimit(2)
                .textSelection(.enabled)
                .help(reason.detail ?? message)
                .accessibilityIdentifier("BrowserEngineFallbackNoticeMessage")
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help(dismissTitle)
            .accessibilityLabel(dismissTitle)
            .accessibilityIdentifier("BrowserEngineFallbackNoticeDismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: backgroundColor))
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("BrowserEngineFallbackNotice")
    }

    private var message: String {
        switch reason {
        case .notBundled:
            String(
                localized: "browser.engineFallback.notBundled",
                defaultValue: "Chromium isn't included in this build, so this tab uses WebKit."
            )
        case .startFailed:
            String(
                localized: "browser.engineFallback.startFailed",
                defaultValue: "Chromium couldn't start, so this tab uses WebKit."
            )
        case .shutDown:
            String(
                localized: "browser.engineFallback.shutDown",
                defaultValue: "Chromium has shut down, so this tab uses WebKit."
            )
        }
    }

    private var dismissTitle: String {
        String(localized: "browser.engineFallback.dismiss", defaultValue: "Dismiss")
    }
}
