import AppKit
import CmuxBrowser
import SwiftUI

/// A one-line strip under the address bar saying the tab opened in WebKit
/// because Chromium was unavailable, shown once per run. It docks to the
/// toolbar (design spec §9), sizes with the browser chrome scale, and fades
/// out over 0.08 s when dismissed while the page below snaps up in one step.
///
/// References: cmux-design-references `apps/t3-code/live/approval-command-and-thread-details.png`
/// (a strip docked to the surface it gates), `apps/cursor/live/import-nudge-dismiss-on-hover.png`
/// (a quiet dismissible notice); cmux Next `CmuxNextApp/ChromiumFallbackLog.swift` (wording).
struct BrowserEngineFallbackNoticeBar: View {
    let reason: BrowserEngineUnavailableReason
    let metrics: BrowserChromeMetrics
    let backgroundColor: NSColor
    /// Opens the Chromium log; offered only when Chromium couldn't start.
    let onShowLog: (() -> Void)?
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isFadingOut = false

    var body: some View {
        HStack(alignment: .center, spacing: metrics.noticeStripHorizontalPadding) {
            Image(systemName: "info.circle")
                .font(.system(size: metrics.noticeStripIconFontSize))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(message)
                .font(.system(size: metrics.noticeStripFontSize))
                .lineLimit(2)
                .textSelection(.enabled)
                // The localized reason only; the engine's raw error text
                // stays in the Chromium log behind Show Log.
                .help(message)
                .accessibilityIdentifier("BrowserEngineFallbackNoticeMessage")
            Spacer(minLength: 0)
            if case .startFailed = reason, let onShowLog {
                Button(showLogTitle, action: onShowLog)
                    .buttonStyle(.plain)
                    .font(.system(size: metrics.noticeStripFontSize))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityIdentifier("BrowserEngineFallbackNoticeShowLog")
            }
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: metrics.noticeStripCloseFontSize, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help(dismissTitle)
            .accessibilityLabel(dismissTitle)
            .accessibilityIdentifier("BrowserEngineFallbackNoticeDismiss")
        }
        .padding(.horizontal, metrics.noticeStripHorizontalPadding)
        .padding(.vertical, metrics.noticeStripVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: backgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 0.5)
        }
        .opacity(isFadingOut ? 0 : 1)
        .onAppear {
            // VoiceOver hears why the tab is WebKit (design spec §0.7a).
            AccessibilityNotification.Announcement(message).post()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("BrowserEngineFallbackNotice")
    }

    /// Fades the strip out, then removes it without animation so the page
    /// snaps up in one step.
    private func dismiss() {
        guard !isFadingOut else { return }
        guard !reduceMotion else {
            onDismiss()
            return
        }
        withAnimation(.easeOut(duration: 0.08), completionCriteria: .logicallyComplete) {
            isFadingOut = true
        } completion: {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { onDismiss() }
        }
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

    private var showLogTitle: String {
        String(localized: "browser.engineFallback.showLog", defaultValue: "Show Log")
    }

    private var dismissTitle: String {
        String(localized: "browser.engineFallback.dismiss", defaultValue: "Dismiss")
    }
}
