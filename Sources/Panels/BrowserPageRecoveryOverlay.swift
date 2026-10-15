import AppKit
import CmuxBrowser
import CmuxFoundation
import SwiftUI

/// What a browser pane asks the user to do before its page comes back.
enum BrowserPageRecoveryPrompt {
    /// The visible page's WebContent process died.
    case crashed
    /// The page was unloaded to save memory and automatic restore is off
    /// (https://github.com/manaflow-ai/cmux/issues/9561). The snapshot is the
    /// page as it looked when the pane was hidden.
    case unloaded(snapshot: BrowserPageSnapshotImage?)
    /// A Chromium panel's load failed and Chromium drew no error page of its
    /// own (`ChromiumNetError.presentation`). Chromium's own error and
    /// certificate pages never get this prompt (design spec §8).
    case chromiumLoadFailed(ChromiumNetError)
    /// A Chromium panel's renderer ended (Chrome's "Aw, Snap!" page).
    /// `isRepeat` is a crash soon after the previous one.
    case chromiumCrashed(BrowserPageProcessExit, isRepeat: Bool)
    /// A Chromium panel's renderer stopped responding (Wait / Exit page).
    case chromiumUnresponsive
}

/// Covers a browser pane whose page is gone until the user brings it back.
struct BrowserPageRecoveryOverlay: View {
    let prompt: BrowserPageRecoveryPrompt
    let backgroundColor: NSColor
    var metrics = BrowserChromeMetrics(tabBarFontSize: BrowserChromeMetrics.referenceFontSize)
    /// Exit page on the Chromium "Page unresponsive" card.
    var exitPageAction: () -> Void = {}
    let action: () -> Void

    var body: some View {
        switch prompt {
        case .crashed:
            ZStack {
                Color(nsColor: backgroundColor)
                    .opacity(0.92)
                Button(action: action) {
                    Label(
                        String(localized: "browser.error.reload", defaultValue: "Reload"),
                        systemImage: "arrow.clockwise"
                    )
                    .cmuxFont(size: 13, weight: .medium)
                    .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .safeHelp(String(localized: "browser.reload", defaultValue: "Reload"))
                .accessibilityIdentifier("BrowserWebContentRecoveryButton")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unloaded(let snapshot):
            ZStack {
                Color(nsColor: backgroundColor)
                if let snapshot, let image = NSImage(data: snapshot.jpegData) {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: snapshot.pointSize.width, height: snapshot.pointSize.height)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .opacity(0.35)
                        .accessibilityHidden(true)
                }
                VStack(spacing: 10) {
                    Text(String(
                        localized: "browser.discard.unloadedMessage",
                        defaultValue: "This page was unloaded to save memory."
                    ))
                    .cmuxFont(size: 13)
                    .foregroundStyle(.secondary)
                    Button(action: action) {
                        Label(
                            String(localized: "browser.discard.restore", defaultValue: "Restore"),
                            systemImage: "arrow.counterclockwise"
                        )
                        .cmuxFont(size: 13, weight: .medium)
                        .padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .accessibilityIdentifier("BrowserUnloadedPageRestoreButton")
                }
                .padding(16)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        case .chromiumLoadFailed(let error):
            ChromiumLoadFailureView(error: error, backgroundColor: backgroundColor, metrics: metrics, reload: action)
        case .chromiumCrashed(let exit, let isRepeat):
            ChromiumPageFailureOverlay(
                failure: .crashed(exit, isRepeat: isRepeat, restoresWhenShown: false),
                metrics: metrics, backgroundColor: backgroundColor,
                primaryAction: action, exitPageAction: exitPageAction
            )
        case .chromiumUnresponsive:
            ChromiumPageFailureOverlay(
                failure: .unresponsive,
                metrics: metrics, backgroundColor: backgroundColor,
                primaryAction: action, exitPageAction: exitPageAction
            )
        }
    }
}

/// cmux's page for a Chromium load failure whose Chromium page is empty:
/// the title WebKit panels use for the same failure, a sentence a person can
/// act on, Chromium's error name on its own line (as Chrome's page shows it),
/// and Reload. Same frame as the crashed prompt so the engines share it.
///
/// References: design spec §8; Chrome `components/error_page_strings.grdp`;
/// cmux Next `CmuxNextBrowser/UI/LoadErrorView.swift`;
/// cmux-design-references `apps/claude/live/browser-panel-empty.png` (centered
/// icon, title, one-line body).
struct ChromiumLoadFailureView: View {
    let error: ChromiumNetError
    let backgroundColor: NSColor
    let metrics: BrowserChromeMetrics
    let reload: () -> Void

    var body: some View {
        ZStack {
            Color(nsColor: backgroundColor)
                .opacity(0.92)
            VStack(spacing: metrics.recoverySpacing) {
                Image(systemName: "exclamationmark.triangle")
                    .cmuxFont(size: metrics.recoveryIconSize)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(title)
                    .cmuxFont(size: metrics.recoveryTitleFontSize, weight: .semibold)
                    .foregroundStyle(.primary)
                Text(sentence)
                    .cmuxFont(size: metrics.recoveryBodyFontSize)
                    .foregroundStyle(.secondary)
                Text(error.name)
                    .cmuxFont(size: metrics.recoveryCaptionFontSize, design: .monospaced)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                Button(action: reload) {
                    Label(
                        String(localized: "browser.error.reload", defaultValue: "Reload"),
                        systemImage: "arrow.clockwise"
                    )
                    .cmuxFont(size: metrics.recoveryBodyFontSize, weight: .medium)
                    .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .padding(.top, metrics.recoverySpacing / 2)
                .accessibilityIdentifier("BrowserChromiumLoadFailureReloadButton")
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: metrics.recoveryMaxWidth)
            .padding(.horizontal, 16)
            .offset(y: -metrics.recoveryVerticalLift)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("BrowserChromiumLoadFailure")
    }

    private var title: String {
        switch error.title {
        case .cantReach:
            String(localized: "browser.error.cantReach.title", defaultValue: "Can\u{2019}t reach this page")
        case .noInternet:
            String(localized: "browser.error.noInternet", defaultValue: "No internet connection")
        case .insecure:
            String(localized: "browser.error.insecure.title", defaultValue: "Connection isn\u{2019}t secure")
        case .cantOpen:
            String(localized: "browser.error.cantOpen.title", defaultValue: "Can\u{2019}t open this page")
        }
    }

    private var sentence: String {
        switch error.detail {
        case .addressNotFound:
            String(localized: "browser.chromium.loadFailure.addressNotFound",
                   defaultValue: "The server\u{2019}s address could not be found.")
        case .refused:
            String(localized: "browser.chromium.loadFailure.refused",
                   defaultValue: "The server refused the connection.")
        case .timedOut:
            String(localized: "browser.chromium.loadFailure.timedOut",
                   defaultValue: "The server took too long to respond.")
        case .offline:
            String(localized: "browser.error.checkNetwork", defaultValue: "Check your network connection and try again.")
        case .certificate:
            String(localized: "browser.error.invalidCertificate", defaultValue: "The certificate for this site is invalid.")
        case .generic:
            String(localized: "browser.error.cantOpen.message",
                   defaultValue: "The page could not be opened. Check the address and try again.")
        }
    }
}
