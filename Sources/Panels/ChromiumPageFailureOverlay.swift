import AppKit
import CmuxBrowser
import CmuxFoundation
import SwiftUI

/// Covers a Chromium pane whose renderer crashed or stopped responding
/// (design spec §8).
///
/// The crash page uses Chrome's own words (`ChromiumPageGone`: "Aw, Snap!"),
/// sits on the same 92% chrome-background veil as the WebKit crash overlay
/// (`BrowserPageRecoveryOverlay`), and offers Reload. The hang prompt is a
/// card with Exit page and Wait. `BrowserPageRecoveryOverlay` hosts it, and
/// the panel mounts that as an occluding page overlay so it shows above a
/// Chromium page window; neither takes keyboard focus on appear.
struct ChromiumPageFailureOverlay: View {
    let failure: ChromiumPageFailureState.Failure
    let metrics: BrowserChromeMetrics
    let backgroundColor: NSColor
    /// Reload (crash page) or Wait (hang prompt).
    let primaryAction: () -> Void
    /// Exit page (hang prompt).
    let exitPageAction: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch failure {
            case .crashed(let exit, let isRepeat, _):
                crashPage(ChromiumPageGone(exit), isRepeat: isRepeat)
            case .unresponsive:
                unresponsiveCard
            }
        }
        .transition(.opacity)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: failure)
    }

    // MARK: Crash page

    private func crashPage(_ gone: ChromiumPageGone, isRepeat: Bool) -> some View {
        ZStack {
            Color(nsColor: backgroundColor)
                .opacity(0.92)
            VStack(spacing: metrics.recoverySpacing) {
                Image(systemName: "exclamationmark.triangle")
                    .cmuxFont(size: metrics.recoveryIconSize)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(gone.title(repeated: isRepeat))
                    .cmuxFont(size: metrics.recoveryTitleFontSize, weight: .semibold)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(gone.message(repeated: isRepeat))
                    .cmuxFont(size: metrics.recoveryBodyFontSize)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: primaryAction) {
                    Label(
                        String(localized: "browser.error.reload", defaultValue: "Reload"),
                        systemImage: "arrow.clockwise"
                    )
                    .cmuxFont(size: metrics.recoveryBodyFontSize, weight: .medium)
                    .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .focusable(false)
                .accessibilityIdentifier("BrowserChromiumCrashReloadButton")
                if let line = gone.errorCodeLine {
                    Text(line)
                        .cmuxFont(size: metrics.recoveryCaptionFontSize)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("BrowserChromiumCrashErrorCode")
                }
            }
            .frame(maxWidth: metrics.recoveryMaxWidth)
            .padding(.horizontal, 16)
            .offset(y: -metrics.recoveryVerticalLift)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("BrowserChromiumCrashPage")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Hang prompt

    private var unresponsiveCard: some View {
        VStack(alignment: .leading, spacing: metrics.unresponsiveCardPadding) {
            Text(String(localized: "browser.chromium.unresponsive.title", defaultValue: "Page unresponsive"))
                .cmuxFont(size: metrics.recoveryBodyFontSize, weight: .semibold)
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
            Text(String(
                localized: "browser.chromium.unresponsive.message",
                defaultValue: "You can wait for it to respond or exit the page."
            ))
            .cmuxFont(size: metrics.recoveryBodyFontSize)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(action: exitPageAction) {
                    Text(String(localized: "browser.chromium.unresponsive.exit", defaultValue: "Exit page"))
                        .cmuxFont(size: metrics.recoveryBodyFontSize)
                }
                .controlSize(.regular)
                .focusable(false)
                .accessibilityIdentifier("BrowserChromiumUnresponsiveExitButton")
                Button(action: primaryAction) {
                    Text(String(localized: "browser.chromium.unresponsive.wait", defaultValue: "Wait"))
                        .cmuxFont(size: metrics.recoveryBodyFontSize, weight: .medium)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .focusable(false)
                .accessibilityIdentifier("BrowserChromiumUnresponsiveWaitButton")
            }
        }
        .padding(metrics.unresponsiveCardPadding)
        .frame(minWidth: metrics.unresponsiveCardMinWidth, maxWidth: metrics.unresponsiveCardMaxWidth, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: metrics.unresponsiveCardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: metrics.unresponsiveCardCornerRadius, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.11), radius: 6, y: 2)
        .padding(16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("BrowserChromiumUnresponsiveCard")
    }
}
