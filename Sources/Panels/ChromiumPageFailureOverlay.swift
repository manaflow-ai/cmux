import AppKit
import CmuxBrowser
import CmuxFoundation
import SwiftUI

/// Covers a Chromium pane whose renderer crashed or stopped responding
/// (design spec §8).
///
/// The crash page uses Chrome's own words ("Aw, Snap!"), sits on the same
/// 92% chrome-background veil as the WebKit crash overlay
/// (`BrowserPageRecoveryOverlay`), and offers Reload. The hang prompt is a
/// card with Exit page and Wait. Neither takes keyboard focus on appear.
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
            case .crashed(let variant, _):
                crashPage(variant)
            case .unresponsive:
                unresponsiveCard
            }
        }
        .transition(.opacity)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: failure)
    }

    // MARK: Crash page

    private func crashPage(_ variant: ChromiumCrashPageVariant) -> some View {
        ZStack {
            Color(nsColor: backgroundColor)
                .opacity(0.92)
            VStack(spacing: metrics.pageFailureSpacing) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: metrics.pageFailureSymbolSize))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(Self.crashTitle(variant))
                    .cmuxFont(size: metrics.pageFailureTitleFontSize, weight: .semibold)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(Self.crashMessage(variant))
                    .cmuxFont(size: metrics.pageFailureBodyFontSize)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: primaryAction) {
                    Label(
                        String(localized: "browser.chromium.crash.reload", defaultValue: "Reload"),
                        systemImage: "arrow.clockwise"
                    )
                    .cmuxFont(size: metrics.pageFailureBodyFontSize, weight: .medium)
                    .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .focusable(false)
                .accessibilityIdentifier("BrowserChromiumCrashReloadButton")
                if let code = variant.errorCode {
                    Text(Self.errorCodeText(code))
                        .cmuxFont(size: metrics.pageFailureCodeFontSize)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("BrowserChromiumCrashErrorCode")
                }
            }
            .frame(maxWidth: metrics.pageFailureMaxWidth)
            .padding(.horizontal, 16)
            .offset(y: -metrics.pageFailureLift)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("BrowserChromiumCrashPage")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func crashTitle(_ variant: ChromiumCrashPageVariant) -> String {
        variant.isRepeat
            ? String(localized: "browser.chromium.crash.repeatTitle", defaultValue: "Can’t open this page")
            : String(localized: "browser.chromium.crash.title", defaultValue: "Aw, Snap!")
    }

    static func crashMessage(_ variant: ChromiumCrashPageVariant) -> String {
        if variant.isRepeat, variant.isOutOfMemory {
            return String(
                localized: "browser.chromium.crash.outOfMemoryMessage",
                defaultValue: "Try closing other tabs or programs to free up memory."
            )
        }
        return String(
            localized: "browser.chromium.crash.message",
            defaultValue: "Something went wrong while displaying this webpage."
        )
    }

    static func errorCodeText(_ code: String) -> String {
        String(
            format: String(localized: "browser.chromium.crash.errorCode", defaultValue: "Error code: %@"),
            code
        )
    }

    // MARK: Hang prompt

    private var unresponsiveCard: some View {
        VStack(alignment: .leading, spacing: metrics.pageFailureCardPadding) {
            Text(String(localized: "browser.chromium.unresponsive.title", defaultValue: "Page unresponsive"))
                .cmuxFont(size: metrics.pageFailureBodyFontSize, weight: .semibold)
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
            Text(String(
                localized: "browser.chromium.unresponsive.message",
                defaultValue: "You can wait for it to respond or exit the page."
            ))
            .cmuxFont(size: metrics.pageFailureBodyFontSize)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(action: exitPageAction) {
                    Text(String(localized: "browser.chromium.unresponsive.exit", defaultValue: "Exit page"))
                        .cmuxFont(size: metrics.pageFailureBodyFontSize)
                }
                .controlSize(.regular)
                .focusable(false)
                .accessibilityIdentifier("BrowserChromiumUnresponsiveExitButton")
                Button(action: primaryAction) {
                    Text(String(localized: "browser.chromium.unresponsive.wait", defaultValue: "Wait"))
                        .cmuxFont(size: metrics.pageFailureBodyFontSize, weight: .medium)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .focusable(false)
                .accessibilityIdentifier("BrowserChromiumUnresponsiveWaitButton")
            }
        }
        .padding(metrics.pageFailureCardPadding)
        .frame(minWidth: metrics.pageFailureCardMinWidth, maxWidth: metrics.pageFailureCardMaxWidth, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: metrics.pageFailureCardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: metrics.pageFailureCardCornerRadius, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.11), radius: 6, y: 2)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("BrowserChromiumUnresponsiveCard")
    }
}
