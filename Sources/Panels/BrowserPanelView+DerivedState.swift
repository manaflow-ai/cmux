import Bonsplit
import SwiftUI
import WebKit
import AppKit
import ObjectiveC


// MARK: - Derived Settings & State
extension BrowserPanelView {
    var searchConfiguration: BrowserSearchConfiguration {
        BrowserSearchSettings.configuration(
            engineRaw: searchEngineRaw,
            customName: customSearchEngineName,
            customURLTemplate: customSearchEngineURLTemplate
        )
    }

    var searchSuggestionsEnabled: Bool {
        // Touch @AppStorage so SwiftUI invalidates this view when settings change.
        _ = searchSuggestionsEnabledStorage
        return BrowserSearchSettings.currentSearchSuggestionsEnabled(defaults: .standard)
    }

    var remoteSuggestionsEnabled: Bool {
        // Deterministic UI-test hook: force remote path on even if a persisted
        // setting disabled suggestions in previous sessions.
        if ProcessInfo.processInfo.environment["CMUX_UI_TEST_REMOTE_SUGGESTIONS_JSON"] != nil ||
            UserDefaults.standard.string(forKey: "CMUX_UI_TEST_REMOTE_SUGGESTIONS_JSON") != nil {
            return true
        }
        // Keep UI tests deterministic by disabling network suggestions when requested.
        if ProcessInfo.processInfo.environment["CMUX_UI_TEST_DISABLE_REMOTE_SUGGESTIONS"] == "1" {
            return false
        }
        return searchSuggestionsEnabled
    }

    var hasActionableOmnibarSuggestions: Bool {
        !omnibarHasMarkedText && !omnibarState.suggestions.isEmpty
    }

    var devToolsIconOption: BrowserDevToolsIconOption {
        BrowserDevToolsIconOption(rawValue: devToolsIconNameRaw) ?? BrowserDevToolsButtonDebugSettings.defaultIcon
    }

    var devToolsColorOption: BrowserDevToolsIconColorOption {
        BrowserDevToolsIconColorOption(rawValue: devToolsIconColorRaw) ?? BrowserDevToolsButtonDebugSettings.defaultColor
    }

    var browserThemeMode: BrowserThemeMode {
        BrowserThemeSettings.mode(for: browserThemeModeRaw)
    }

    private var browserImportHintVariant: BrowserImportHintVariant {
        BrowserImportHintSettings.variant(for: browserImportHintVariantRaw)
    }

    var browserImportHintPresentation: BrowserImportHintPresentation {
        BrowserImportHintPresentation(
            variant: browserImportHintVariant,
            showOnBlankTabs: showBrowserImportHintOnBlankTabs,
            isDismissed: isBrowserImportHintDismissed
        )
    }

    var browserToolbarAccessorySpacing: CGFloat {
        CGFloat(BrowserToolbarAccessorySpacingDebugSettings.resolved(browserToolbarAccessorySpacingRaw))
    }

    var browserProfilePopoverHorizontalPadding: CGFloat {
        CGFloat(BrowserProfilePopoverDebugSettings.resolvedHorizontalPadding(browserProfilePopoverHorizontalPaddingRaw))
    }

    var browserProfilePopoverVerticalPadding: CGFloat {
        CGFloat(BrowserProfilePopoverDebugSettings.resolvedVerticalPadding(browserProfilePopoverVerticalPaddingRaw))
    }

    var browserChromeBackground: Color {
        Color(nsColor: browserChromeStyle.backgroundColor)
    }

    var browserChromeBackgroundColor: NSColor {
        browserChromeStyle.backgroundColor
    }

    var browserChromeColorScheme: ColorScheme {
        browserChromeStyle.colorScheme
    }

    var browserContentAccessibilityIdentifier: String {
        "BrowserPanelContent.\(panel.id.uuidString)"
    }

    var omnibarPillBackgroundColor: NSColor {
        browserChromeStyle.omnibarPillBackgroundColor
    }

    private var hasVisibleOmnibarSuggestions: Bool {
        panel.isOmnibarVisible && addressBarFocused && hasActionableOmnibarSuggestions && omnibarPillFrame.width > 0
    }

    var shouldRenderOmnibarSuggestionsInPortal: Bool {
        hasVisibleOmnibarSuggestions &&
            panel.shouldRenderWebView &&
            !panel.shouldUseLocalInlineDeveloperToolsHosting()
    }

    var shouldRenderOmnibarSuggestionsInSwiftUI: Bool {
        hasVisibleOmnibarSuggestions && !shouldRenderOmnibarSuggestionsInPortal
    }

    private var omnibarSuggestionsFrameInPortal: CGRect? {
        guard shouldRenderOmnibarSuggestionsInPortal else { return nil }
        let top = max(0, omnibarPillFrame.maxY + 3 - addressBarHeight)
        let height = OmnibarSuggestionsView.popupHeight(for: omnibarState.suggestions)
        guard omnibarPillFrame.width > 0, height > 0 else { return nil }
        return CGRect(
            x: omnibarPillFrame.minX,
            y: top,
            width: omnibarPillFrame.width,
            height: height
        )
    }

    var portalOmnibarSuggestions: BrowserPortalOmnibarSuggestionsConfiguration? {
        guard let frame = omnibarSuggestionsFrameInPortal else { return nil }
        return BrowserPortalOmnibarSuggestionsConfiguration(
            panelId: panel.id,
            popupFrame: frame,
            colorScheme: browserChromeColorScheme,
            engineName: searchConfiguration.displayName,
            items: omnibarState.suggestions,
            selectedIndex: omnibarState.selectedSuggestionIndex,
            isLoadingRemoteSuggestions: isLoadingRemoteSuggestions,
            searchSuggestionsEnabled: remoteSuggestionsEnabled,
            onCommit: { item in
                commitSuggestion(item)
            },
            onHighlight: { idx in
                let effects = omnibarReduce(state: &omnibarState, event: .highlightIndex(idx))
                applyOmnibarEffects(effects)
            }
        )
    }

    var developerToolsButtonHelp: String {
        let base = String(localized: "browser.toggleDevTools", defaultValue: "Toggle Developer Tools")
        let _ = keyboardShortcutSettingsObserver.revision
        return "\(base) (\(KeyboardShortcutSettings.shortcut(for: .toggleBrowserDeveloperTools).displayString))"
    }

    var browserImportHintSummary: String {
        InstalledBrowserDetector.summaryText(for: emptyStateImportBrowsers)
    }

    var shouldShowToolbarImportHintChip: Bool {
        shouldShowEmptyStateImportOverlay && browserImportHintPresentation.blankTabPlacement == .toolbarChip
    }

    var owningWorkspace: Workspace? {
        guard let app = AppDelegate.shared,
              let manager = app.tabManagerFor(tabId: panel.workspaceId) else {
            return nil
        }
        return manager.tabs.first(where: { $0.id == panel.workspaceId })
    }

    var isCurrentPaneOwner: Bool {
        guard let currentPaneId = owningWorkspace?.paneId(forPanelId: panel.id) else {
            return false
        }
        return currentPaneId.id == paneId.id
    }

    var currentEventIsCommandPointerActivation: Bool {
        guard let event = NSApp.currentEvent else { return false }
        switch event.type {
        case .leftMouseUp:
            break
        default:
            return false
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return flags.contains(.command)
    }

}
