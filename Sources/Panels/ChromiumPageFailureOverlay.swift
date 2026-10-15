import AppKit
import CmuxBrowser
import CmuxFoundation
import SwiftUI

/// Covers a Chromium pane whose renderer crashed or stopped responding
/// (design spec §8).
///
/// The crash page uses Chrome's own words (`ChromiumPageGone`: "Aw, Snap!"),
/// sits on the opaque chrome background (the WebKit crash overlay's 0.92 veil
/// would only show the host placeholder through the page window's hole, spec
/// §0.9), and offers Reload under the error code. The hang prompt is an
/// opaque card with Exit page and Wait. `BrowserPageRecoveryOverlay` hosts it, and
/// the panel mounts that as an occluding page overlay so it shows above a
/// Chromium page window; neither takes keyboard focus on appear.
struct ChromiumPageFailureOverlay: View {
    let failure: ChromiumPageFailureState.Failure
    let metrics: BrowserChromeMetrics
    let backgroundColor: NSColor
    /// The panel's page overlay coordinator; the hang card cuts its own
    /// notched hole through it.
    var overlays: BrowserPageOverlayCoordinator?
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
            // Opaque: under the page window's hole there is no page to see
            // through, only the host's placeholder (spec §0.9).
            Color(nsColor: backgroundColor)
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
                // Chrome's sad tab order: message, error code, then Reload.
                if let line = gone.errorCodeLine {
                    Text(line)
                        .cmuxFont(size: metrics.recoveryCaptionFontSize)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("BrowserChromiumCrashErrorCode")
                }
                Button(action: primaryAction) {
                    Label(
                        String(localized: "browser.error.reload", defaultValue: "Reload"),
                        systemImage: "arrow.clockwise"
                    )
                    .cmuxFont(size: metrics.recoveryBodyFontSize, weight: .medium)
                    .padding(.horizontal, metrics.pageFailureButtonLabelPadding)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .focusable(false)
                .padding(.top, metrics.recoverySpacing / 2)
                .accessibilityIdentifier("BrowserChromiumCrashReloadButton")
            }
            .frame(maxWidth: metrics.recoveryMaxWidth)
            .padding(.horizontal, metrics.pageFailureHorizontalInset)
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
            HStack(spacing: metrics.unresponsiveCardButtonSpacing) {
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
        // Opaque fill and a hairline instead of material and a shadow: the
        // card shows through a hole in the page window, where material would
        // blur cmux's views and a shadow would be clipped (spec §0.9).
        .background(
            Color(nsColor: .windowBackgroundColor),
            in: RoundedRectangle(cornerRadius: metrics.unresponsiveCardCornerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: metrics.unresponsiveCardCornerRadius, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .background(cardHole)
        .padding(metrics.pageFailureHorizontalInset)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("BrowserChromiumUnresponsiveCard")
    }

    /// The card's hole in the page window: exactly the card, not the space
    /// around it, so the frozen page stays visible around the card. One rect:
    /// the page window honours a single hole per overlay today, so the
    /// notched three-band hole of spec §0.9 waits for multi-rect support (a
    /// band-split hole showed only its first band); until then the four
    /// corner arcs show the pane background.
    private var cardHole: some View {
        Color.clear
            .browserPageOccluding(overlays, id: "pageFailure.card")
            .accessibilityHidden(true)
    }
}

extension BrowserPageRecoveryPrompt {
    /// Whether the prompt registers its own page-window hole (the hang card,
    /// sized to the card) instead of one hole for the whole overlay.
    var registersOwnPageOcclusion: Bool {
        if case .chromiumUnresponsive = self { return true }
        return false
    }
}
