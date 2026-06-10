import Bonsplit
import SwiftUI
import WebKit
import AppKit
import ObjectiveC


// MARK: - Empty State & Import Hint
extension BrowserPanelView {
    var emptyBrowserStateCardOverlay: some View {
        VStack {
            Spacer(minLength: 22)

            browserImportHintBody
            .padding(12)
            .frame(maxWidth: 360, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.9))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(
                    Color(nsColor: .separatorColor).opacity(0.45),
                    lineWidth: 1
                )
            )
            .shadow(color: Color.black.opacity(0.08), radius: 8, y: 3)

            Spacer()
        }
        .padding(.horizontal, 18)
    }

    var emptyBrowserStateInlineStrip: some View {
        VStack(alignment: .leading, spacing: 0) {
            browserImportHintBody
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: 520, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.84))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(
                        Color(nsColor: .separatorColor).opacity(0.35),
                        lineWidth: 1
                    )
                )
                .shadow(color: Color.black.opacity(0.05), radius: 6, y: 2)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
    }

    var browserImportHintPopover: some View {
        browserImportHintBody
            .padding(12)
            .frame(width: 300, alignment: .leading)
    }

    private var browserImportHintBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "browser.import.hint.title", defaultValue: "Import browser data"))
                .font(.system(size: 12.5, weight: .semibold))

            Text(browserImportHintSummary)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(String(localized: "browser.import.hint.settingsFootnote", defaultValue: "You can always find this in Settings > Browser."))
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    browserImportHintPrimaryButton
                    browserImportHintSettingsButton
                    browserImportHintDismissButton
                }

                VStack(alignment: .leading, spacing: 8) {
                    browserImportHintPrimaryButton
                    HStack(spacing: 10) {
                        browserImportHintSettingsButton
                        browserImportHintDismissButton
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var browserImportHintPrimaryButton: some View {
        Button(String(localized: "browser.import.hint.import", defaultValue: "Import…")) {
            presentImportDialogFromHint()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityIdentifier("BrowserImportHintImportButton")
    }

    private var browserImportHintSettingsButton: some View {
        Button(String(localized: "browser.import.hint.settings", defaultValue: "Browser Settings")) {
            openBrowserImportSettings()
        }
        .buttonStyle(.plain)
        .controlSize(.small)
        .accessibilityIdentifier("BrowserImportHintSettingsButton")
    }

    private var browserImportHintDismissButton: some View {
        Button(String(localized: "browser.import.hint.dismiss", defaultValue: "Hide Hint")) {
            dismissBrowserImportHint()
        }
        .buttonStyle(.plain)
        .controlSize(.small)
        .accessibilityIdentifier("BrowserImportHintDismissButton")
    }

    var shouldShowEmptyStateImportOverlay: Bool {
        panel.isShowingNewTabPage
    }

    private func presentImportDialogFromHint() {
        isBrowserImportHintPopoverPresented = false
        DispatchQueue.main.async {
            BrowserDataImportCoordinator.shared.presentImportDialog(
                defaultDestinationProfileID: panel.profileID
            )
        }
    }

    func presentImportDialogFromProfileMenu() {
        isBrowserProfileMenuPresented = false
        DispatchQueue.main.async {
            BrowserDataImportCoordinator.shared.presentImportDialog(
                defaultDestinationProfileID: panel.profileID
            )
        }
    }

    private func openBrowserImportSettings() {
        isBrowserImportHintPopoverPresented = false
        SettingsWindowPresenter.show(
            navigationTarget: .browserImport,
            openWindowOverride: { openWindow(id: SettingsWindowPresenter.windowID) }
        )
        NSRunningApplication.current.activate(options: [.activateAllWindows])
    }

    private func dismissBrowserImportHint() {
        showBrowserImportHintOnBlankTabs = false
        isBrowserImportHintDismissed = true
        isBrowserImportHintPopoverPresented = false
    }

    /// Treat content as blank only if neither WebKit nor the panel model has a nonblank URL.
    func isBrowserContentBlankForOmnibar() -> Bool {
        panel.preferredURLStringForOmnibar() == nil
    }

    func autoFocusOmnibarIfBlank() {
        guard panel.isOmnibarVisible else {
#if DEBUG
            logBrowserFocusState(event: "addressBarFocus.autoFocus.skip", detail: "reason=omnibar_hidden")
#endif
            return
        }
        guard isFocused else {
#if DEBUG
            logBrowserFocusState(event: "addressBarFocus.autoFocus.skip", detail: "reason=panel_not_focused")
#endif
            return
        }
        guard !addressBarFocused else {
#if DEBUG
            logBrowserFocusState(event: "addressBarFocus.autoFocus.skip", detail: "reason=already_focused")
#endif
            return
        }
        guard !isCommandPaletteVisibleForPanelWindow() else {
#if DEBUG
            logBrowserFocusState(event: "addressBarFocus.autoFocus.skip", detail: "reason=command_palette_visible")
#endif
            return
        }
        // If a test/automation explicitly focused WebKit, don't steal focus back.
        guard !panel.shouldSuppressOmnibarAutofocus() else {
#if DEBUG
            logBrowserFocusState(event: "addressBarFocus.autoFocus.skip", detail: "reason=autofocus_suppressed")
#endif
            return
        }
        // If a real navigation is underway (e.g. open_browser https://...), don't steal focus.
        guard !panel.webView.isLoading else {
#if DEBUG
            logBrowserFocusState(event: "addressBarFocus.autoFocus.skip", detail: "reason=webview_loading")
#endif
            return
        }
        guard isBrowserContentBlankForOmnibar() else {
#if DEBUG
            logBrowserFocusState(event: "addressBarFocus.autoFocus.skip", detail: "reason=webview_not_blank")
#endif
            return
        }
        setAddressBarFocused(true, reason: "autoFocus.blank")
#if DEBUG
        logBrowserFocusState(event: "addressBarFocus.autoFocus.apply")
#endif
    }

    func refreshEmptyStateImportBrowsers() {
        emptyStateImportBrowserRefreshTask?.cancel()
        emptyStateImportBrowserRefreshGeneration &+= 1
        let generation = emptyStateImportBrowserRefreshGeneration

        guard shouldShowEmptyStateImportOverlay else {
            emptyStateImportBrowsers = []
            emptyStateImportBrowserRefreshTask = nil
            return
        }

        emptyStateImportBrowserRefreshTask = Task {
            let browsers = await Task.detached(priority: .utility) {
                InstalledBrowserDetector.detectInstalledBrowsers()
            }.value
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard emptyStateImportBrowserRefreshGeneration == generation,
                      shouldShowEmptyStateImportOverlay else { return }
                emptyStateImportBrowsers = browsers
                emptyStateImportBrowserRefreshTask = nil
            }
        }
    }

}
