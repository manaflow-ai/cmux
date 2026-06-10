import Bonsplit
import SwiftUI
import WebKit
import AppKit
import ObjectiveC


// MARK: - Panel Content & Overlay Views
extension BrowserPanelView {
    @ViewBuilder
    private var browserFindOverlayView: some View {
        // Keep browser find usable when the browser is still in the empty new-tab
        // state (no WKWebView mounted yet). WebView-backed cases are hosted
        // in AppKit by WindowBrowserPortal to avoid layering/clipping issues.
        if !panel.shouldRenderWebView, let searchState = panel.searchState {
            BrowserSearchOverlay(
                panelId: panel.id,
                searchState: searchState,
                focusRequestGeneration: panel.searchFocusRequestGeneration,
                canApplyFocusRequest: { generation in
                    canApplyBrowserFindFieldFocusRequest(generation)
                },
                onNext: { panel.findNext() },
                onPrevious: { panel.findPrevious() },
                onClose: { panel.hideFind() },
                onFieldDidFocus: { panel.noteFindFieldFocused() }
            )
        }
    }

    private var focusFlashOverlayView: some View {
        RoundedRectangle(cornerRadius: FocusFlashPattern.ringCornerRadius)
            .stroke(cmuxAccentColor().opacity(focusFlashOpacity), lineWidth: 3)
            .shadow(color: cmuxAccentColor().opacity(focusFlashOpacity * 0.35), radius: 10)
            .padding(FocusFlashPattern.ringInset)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var omnibarSuggestionsOverlayView: some View {
        if shouldRenderOmnibarSuggestionsInSwiftUI {
            OmnibarSuggestionsView(
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
            .frame(width: omnibarPillFrame.width)
            .offset(x: omnibarPillFrame.minX, y: omnibarPillFrame.maxY + 3)
            .zIndex(1000)
            .environment(\.colorScheme, browserChromeColorScheme)
        }
    }

    @ViewBuilder
    private var omnibarHeaderView: some View {
        if panel.isOmnibarVisible {
            addressBar
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var browserPanelBaseView: some View {
        // Layering contract: browser find UI is mounted in the portal-hosted AppKit
        // container. Rendering it here can hide it behind the portal-hosted WKWebView.
        VStack(spacing: 0) {
            omnibarHeaderView
            webView
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(browserFindOverlayView)
        .overlay(focusFlashOverlayView)
        .overlay(omnibarSuggestionsOverlayView, alignment: .topLeading)
    }

    var browserPanelLifecycleView: some View {
        browserPanelBaseView
        .coordinateSpace(name: "BrowserPanelViewSpace")
        .onPreferenceChange(OmnibarPillFramePreferenceKey.self) { frame in
            omnibarPillFrame = frame
        }
        .onPreferenceChange(BrowserAddressBarHeightPreferenceKey.self) { height in
            addressBarHeight = height
        }
        .onReceive(NotificationCenter.default.publisher(for: .webViewDidReceiveClick)) { notification in
            handleBrowserWebViewClickIntent(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyConfigDidReload)) { _ in
            tabBarFontSize = GhosttyConfig.load().surfaceTabBarFontSize
        }
        .onAppear {
            handleBrowserPanelAppear()
        }
        .onDisappear {
            handleBrowserPanelDisappear()
        }
        .onChange(of: panel.focusFlashToken) { _ in
            triggerFocusFlashAnimation()
        }
        .onChange(of: panel.currentURL) { _ in
            handleCurrentURLChange()
        }
        .onChange(of: panel.shouldRenderWebView) { _, _ in
            handleRenderWebViewChange()
        }
        .onChange(of: panel.backgroundAppearanceRevision) { _, _ in
            refreshBrowserChromeStyle()
        }
        .onChange(of: browserThemeModeRaw) { _ in
            handleBrowserThemeModeRawChange()
        }
        .onChange(of: colorScheme) { _ in
            handleSystemColorSchemeChange()
        }
        .onChange(of: panel.pendingAddressBarFocusRequestId) { _ in
            applyPendingAddressBarFocusRequestIfNeeded()
        }
        .onChange(of: panel.isOmnibarVisible) { _, isVisible in
            handleOmnibarVisibilityChange(isVisible)
        }
    }

    var omnibarField: some View {
        let showSecureBadge = panel.currentURL?.scheme == "https"

        return HStack(spacing: 4) {
            if showSecureBadge {
                Image(systemName: "lock.fill")
                    .font(.system(size: chromeMetrics.secureBadgeFontSize))
                    .foregroundColor(.secondary)
            }

            OmnibarTextFieldRepresentable(
                panelId: panel.id,
                fontSize: chromeMetrics.omnibarFontSize,
                text: Binding(
                    get: { omnibarState.buffer },
                    set: { newValue in
                        let effects = omnibarReduce(state: &omnibarState, event: .bufferChanged(newValue))
                        applyOmnibarEffects(effects)
                        if !effects.shouldClearInlineCompletion {
                            refreshInlineCompletion()
                        }
                    }
                ),
                isFocused: $addressBarFocused,
                selectAllRequestId: omnibarSelectAllRequestId,
                inlineCompletion: inlineCompletion,
                placeholder: String(localized: "browser.addressBar.placeholder", defaultValue: "Search or enter URL"),
                onTap: {
                    handleOmnibarTap()
                },
                onSubmit: {
                    if canHandleOmnibarSuggestionInteraction() {
                        commitSelectedSuggestion()
                    } else {
                        panel.navigateSmart(omnibarState.buffer)
                        hideSuggestions()
                        suppressNextFocusLostRevert = true
                        setAddressBarFocused(false, reason: "omnibar.submit.navigate")
                    }
                },
                onEscape: {
                    handleOmnibarEscape()
                },
                onFieldLostFocus: {
                    setAddressBarFocused(false, reason: "omnibar.fieldLostFocus")
                },
                onMoveSelection: { delta in
                    guard canHandleOmnibarSuggestionInteraction() else { return }
                    let effects = omnibarReduce(state: &omnibarState, event: .moveSelection(delta: delta))
                    applyOmnibarEffects(effects)
                    refreshInlineCompletion()
                },
                onDeleteSelectedSuggestion: {
                    deleteSelectedSuggestionIfPossible()
                },
                onAcceptInlineCompletion: {
                    acceptInlineCompletion()
                },
                onDeleteBackwardWithInlineSelection: {
                    handleInlineBackspace()
                },
                onClearTypedPrefixWithInlineSelection: {
                    handleInlineClearTypedPrefix()
                },
                onDeleteWordBackwardWithInlineSelection: {
                    handleInlineDeleteWordBackward()
                },
                onSelectionChanged: { selectionRange, hasMarkedText in
                    handleOmnibarSelectionChange(range: selectionRange, hasMarkedText: hasMarkedText)
                },
                shouldSuppressWebViewFocus: {
                    panel.shouldSuppressWebViewFocus()
                }
            )
                .frame(height: chromeMetrics.omnibarFieldHeight)
                .accessibilityIdentifier("BrowserOmnibarTextField")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: omnibarPillCornerRadius, style: .continuous)
                .fill(Color(nsColor: omnibarPillBackgroundColor))
        )
        .overlay {
            BrowserOmnibarInteractionRepresentable(panelId: panel.id)
        }
        .overlay(
            RoundedRectangle(cornerRadius: omnibarPillCornerRadius, style: .continuous)
                .stroke(addressBarFocused ? cmuxAccentColor() : Color.clear, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .background {
            GeometryReader { geo in
                Color.clear
                    .preference(
                        key: OmnibarPillFramePreferenceKey.self,
                        value: geo.frame(in: .named("BrowserPanelViewSpace"))
                    )
            }
        }
    }

    private var webView: some View {
        let useLocalInlineDeveloperToolsHosting =
            panel.shouldUseLocalInlineDeveloperToolsHosting() &&
            isCurrentPaneOwner

        return Group {
            if panel.shouldRenderWebView {
                WebViewRepresentable(
                    panel: panel,
                    paneId: paneId,
                    shouldAttachWebView: isVisibleInUI && isCurrentPaneOwner && !useLocalInlineDeveloperToolsHosting,
                    useLocalInlineHosting: useLocalInlineDeveloperToolsHosting,
                    shouldFocusWebView: isFocused && !addressBarFocused,
                    isPanelFocused: isFocused,
                    portalZPriority: portalPriority,
                    paneDropZone: paneDropZone,
                    searchOverlay: panel.searchState.map { searchState in
                        BrowserPortalSearchOverlayConfiguration(
                            panelId: panel.id,
                            searchState: searchState,
                            focusRequestGeneration: panel.searchFocusRequestGeneration,
                            canApplyFocusRequest: { generation in
                                canApplyBrowserFindFieldFocusRequest(generation)
                            },
                            onNext: { panel.findNext() },
                            onPrevious: { panel.findPrevious() },
                            onClose: { panel.hideFind() },
                            onFieldDidFocus: { panel.noteFindFieldFocused() }
                        )
                    },
                    omnibarSuggestions: portalOmnibarSuggestions,
                    paneTopChromeHeight: panel.isOmnibarVisible ? addressBarHeight : 0
                )
                .accessibilityIdentifier("BrowserWebViewSurface")
                // Keep the host stable for normal pane churn, but force a remount when
                // BrowserPanel replaces its underlying WKWebView after process termination
                // or when the browser moves to a different Bonsplit pane host.
                .id("\(panel.webViewInstanceID.uuidString)-\(paneId.id.uuidString)")
                .contentShape(Rectangle())
                .accessibilityIdentifier(browserContentAccessibilityIdentifier)
                .simultaneousGesture(TapGesture().onEnded {
                    // Chrome-like behavior: clicking web content while editing the
                    // omnibar should commit blur and revert transient edits.
                    if addressBarFocused {
#if DEBUG
                        logBrowserFocusState(event: "webContent.tapBlur")
#endif
                        setAddressBarFocused(false, reason: "webContent.tapBlur")
                    }
                })
            } else {
                Color(nsColor: browserChromeBackgroundColor)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier(browserContentAccessibilityIdentifier)
                    .onTapGesture {
                        onRequestPanelFocus()
                        if addressBarFocused {
                            setAddressBarFocused(false, reason: "placeholderContent.tapBlur")
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if shouldShowEmptyStateImportOverlay,
                           browserImportHintPresentation.blankTabPlacement == .inlineStrip {
                            emptyBrowserStateInlineStrip
                        }
                    }
                    .overlay {
                        if shouldShowEmptyStateImportOverlay,
                           browserImportHintPresentation.blankTabPlacement == .floatingCard {
                            emptyBrowserStateCardOverlay
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay {
            if panel.hasRecoverableWebContentTermination {
                webContentRecoveryOverlay
            }
        }
        .layoutPriority(1)
        .zIndex(0)
    }

    private var webContentRecoveryOverlay: some View {
        ZStack {
            Color(nsColor: browserChromeBackgroundColor)
                .opacity(0.92)
            Button(action: {
                panel.recoverTerminatedWebContent(reason: "overlayButton")
            }) {
                Label(
                    String(localized: "browser.error.reload", defaultValue: "Reload"),
                    systemImage: "arrow.clockwise"
                )
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .safeHelp(String(localized: "browser.reload", defaultValue: "Reload"))
            .accessibilityIdentifier("BrowserWebContentRecoveryButton")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}
