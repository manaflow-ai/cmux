import AppKit
import Bonsplit
import CmuxBrowser
import CmuxFoundation
import CmuxSettings
import Combine
import WebKit

@MainActor
final class BrowserPanelNativeViewController: NSViewController, PanelContentControllerUpdating {
    private final class RootView: NSView {
        override var isFlipped: Bool { true }
    }

    private final class PlaceholderView: NSView {
        var onPointerDown: (() -> Void)?

        override func mouseDown(with event: NSEvent) {
            onPointerDown?()
            super.mouseDown(with: event)
        }
    }

    private var configuration: PanelContentConfiguration
    private let panel: BrowserPanel
    private let rootView = RootView()
    private let toolbarView = NSView()
    private let navigationStack = NSStackView()
    private let accessoryStack = NSStackView()
    private let omnibarPillView = NSView()
    private let secureBadgeView = NSImageView()
    private let omnibarInteractionView = BrowserOmnibarInteractionView(frame: .zero)
    private let contentContainer = NSView()
    private let placeholderView = PlaceholderView()
    private let recoveryOverlay = NSView()
    private let recoveryButton = NSButton()
    private let flashRing = WorkspaceAttentionFlashRingNativeView(frame: .zero)
    private let webHost = BrowserWebViewNativeConfiguration.NativeHost()
    private var localSearchOverlay: BrowserSearchOverlay?
    private var localSuggestionsHost: BrowserPortalOmnibarSuggestionsHostingView?
    private var toolbarHeightConstraint: NSLayoutConstraint!

    private let backButton = BrowserToolbarButton()
    private let forwardButton = BrowserToolbarButton()
    private let reloadButton = BrowserToolbarButton()
    private let pdfDownloadButton = BrowserToolbarButton()
    private let pdfPrintButton = BrowserToolbarButton()
    private let downloadsButton = BrowserDownloadsToolbarButtonView(frame: .zero)
    private let importButton = BrowserToolbarButton()
    private let overflowButton = BrowserToolbarButton()
    private let focusModeButton = BrowserToolbarButton()
    private let designModeButton = BrowserDesignModeToolbarButtonView(frame: .zero)
    private let screenshotButton = BrowserToolbarButton()
    private let profileButton = BrowserToolbarButton()
    private let themeButton = BrowserToolbarButton()
    private let developerToolsButton = BrowserToolbarButton()

    private lazy var omnibarHost = OmnibarTextFieldNativeHost(
        configuration: omnibarConfiguration
    )

    private var omnibarState = OmnibarState()
    private var addressBarFocused = false
    private var pendingFocusGainedSelectionIntent: BrowserAddressBarFocusSelectionIntent = .preserveFieldEditorSelection
    private var suppressNextFocusLostRevert = false
    private var lastHandledAddressBarFocusRequestId: UUID?
    private var omnibarSelectAllRequestId: UInt64 = 0
    private var omnibarSelectionRange = NSRange(location: NSNotFound, length: 0)
    private var omnibarHasMarkedText = false
    private var inlineCompletion: OmnibarInlineCompletion?
    private let suggestionScheduler = OmnibarSuggestionRefreshScheduler()
    private var suggestionConsumerTask: Task<Void, Never>?
    private var suggestionTask: Task<Void, Never>?
    private var latestRemoteSuggestionQuery = ""
    private var latestRemoteSuggestions: [String] = []
    private var isLoadingRemoteSuggestions = false
    private var screenshotTask: Task<Void, Never>?
    private var screenshotIndicatorTask: Task<Void, Never>?
    private var screenshotPageCopied = false
    private var screenshotCaptureInProgress = false
    private var renderTask: Task<Void, Never>?
    private var notificationTasks: [Task<Void, Never>] = []
    private var panelCancellable: AnyCancellable?
    private var historyCancellable: AnyCancellable?
    private var isTornDown = false
    private var didAppear = false
    private var lastURL: URL?
    private var lastShouldRenderWebView: Bool
    private var lastFocusFlashToken: Int
    private var lastProfileID: UUID
    private var lastOmnibarVisible: Bool
    private var tabBarFontSize = GhosttyConfig.load(
        globalFontMagnificationPercent: GlobalFontMagnification.storedPercent
    ).surfaceTabBarFontSize

    init(configuration: PanelContentConfiguration) {
        guard let panel = configuration.panel as? BrowserPanel else {
            preconditionFailure("BrowserPanelNativeViewController requires BrowserPanel")
        }
        self.configuration = configuration
        self.panel = panel
        lastURL = panel.currentURL
        lastShouldRenderWebView = panel.shouldRenderWebView
        lastFocusFlashToken = panel.focusFlashToken
        lastProfileID = panel.profileID
        lastOmnibarVisible = panel.isOmnibarVisible
        super.init(nibName: nil, bundle: nil)
        startObserving()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        configureViewHierarchy()
        view = rootView
        syncURLFromPanel()
        render()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        handleAppearIfNeeded()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateCompactChrome()
        updateBrowserHost()
        updateLocalSuggestions()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        panel.noteWebViewVisibility(false, reason: "nativeView.willDisappear")
    }

    func update(configuration: PanelContentConfiguration) {
        guard configuration.panel === panel else { return }
        let previousFocused = self.configuration.isFocused
        let previousVisible = self.configuration.isVisibleInUI
        self.configuration = configuration
        loadViewIfNeeded()
        if previousFocused != configuration.isFocused {
            handlePanelFocusChange(configuration.isFocused)
        }
        if previousVisible != configuration.isVisibleInUI {
            handlePanelVisibilityChange(configuration.isVisibleInUI)
        }
        render()
    }

    func teardownPanelContent() {
        guard !isTornDown else { return }
        isTornDown = true
        renderTask?.cancel()
        suggestionConsumerTask?.cancel()
        suggestionTask?.cancel()
        screenshotTask?.cancel()
        screenshotIndicatorTask?.cancel()
        notificationTasks.forEach { $0.cancel() }
        notificationTasks.removeAll(keepingCapacity: false)
        panelCancellable?.cancel()
        historyCancellable?.cancel()
        downloadsButton.teardown()
        omnibarHost.teardown()
        webHost.teardown()
        localSearchOverlay?.removeFromSuperview()
        localSuggestionsHost?.removeFromSuperview()
        panel.noteWebViewVisibility(false, reason: "nativeView.teardown")
    }

    private var metrics: BrowserChromeMetrics {
        BrowserChromeMetrics(tabBarFontSize: tabBarFontSize)
    }

    private var owningWorkspace: Workspace? {
        guard let app = AppDelegate.shared,
              let manager = app.tabManagerFor(tabId: panel.workspaceId) else {
            return nil
        }
        return manager.tabs.first(where: { $0.id == panel.workspaceId })
    }

    private var isCurrentPaneOwner: Bool {
        if let override = configuration.paneOwnershipOverride {
            return override
        }
        return owningWorkspace?.paneId(forPanelId: panel.id)?.id == configuration.paneID.id
    }

    private var browserThemeMode: BrowserThemeMode {
        BrowserThemeSettings.mode(defaults: .standard)
    }

    private var searchConfiguration: BrowserSearchConfiguration {
        BrowserSearchSettingsStore().configuration(
            engineRaw: UserDefaults.standard.string(forKey: BrowserSearchSettingsStore.searchEngineKey)
                ?? BrowserSearchSettingsStore.defaultSearchEngine.rawValue,
            customName: UserDefaults.standard.string(forKey: BrowserSearchSettingsStore.customSearchEngineNameKey)
                ?? BrowserSearchSettingsStore.defaultCustomSearchEngineName,
            customURLTemplate: UserDefaults.standard.string(forKey: BrowserSearchSettingsStore.customSearchEngineURLTemplateKey)
                ?? BrowserSearchSettingsStore.defaultCustomSearchEngineURLTemplate
        )
    }

    private var remoteSuggestionsEnabled: Bool {
        if ProcessInfo.processInfo.environment["CMUX_UI_TEST_REMOTE_SUGGESTIONS_JSON"] != nil ||
            UserDefaults.standard.string(forKey: "CMUX_UI_TEST_REMOTE_SUGGESTIONS_JSON") != nil {
            return true
        }
        if ProcessInfo.processInfo.environment["CMUX_UI_TEST_DISABLE_REMOTE_SUGGESTIONS"] == "1" {
            return false
        }
        return BrowserSearchSettingsStore(defaults: .standard).currentSearchSuggestionsEnabled
    }

    private var chromeIsDark: Bool {
        rootView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private var chromeBackgroundColor: NSColor {
        guard panel.drawsConfiguredWebViewBackgroundForCurrentPage() else { return .clear }
        return GhosttyBackgroundTheme.currentColor()
    }

    private var omnibarBackgroundColor: NSColor {
        let base = GhosttyBackgroundTheme.currentColor()
        let fraction: CGFloat = chromeIsDark ? 0.05 : 0.04
        return (base.blended(withFraction: fraction, of: .black) ?? base)
            .withAlphaComponent(base.alphaComponent)
    }

    private func configureViewHierarchy() {
        rootView.wantsLayer = true
        toolbarView.wantsLayer = true
        omnibarPillView.wantsLayer = true
        omnibarPillView.layer?.cornerRadius = 10
        omnibarPillView.setAccessibilityElement(false)
        contentContainer.wantsLayer = true
        placeholderView.wantsLayer = true
        placeholderView.onPointerDown = { [weak self] in
            guard let self else { return }
            self.configuration.onRequestPanelFocus()
            if self.addressBarFocused {
                self.setAddressBarFocused(false, reason: "placeholder.pointerDown")
            }
        }

        navigationStack.orientation = .horizontal
        navigationStack.alignment = .centerY
        navigationStack.spacing = 0
        accessoryStack.orientation = .horizontal
        accessoryStack.alignment = .centerY
        accessoryStack.spacing = CGFloat(BrowserToolbarAccessorySpacingDebugSettings.current())

        configureButton(backButton, symbol: "chevron.left", identifier: "BrowserBackButton", action: #selector(goBack))
        configureButton(forwardButton, symbol: "chevron.right", identifier: "BrowserForwardButton", action: #selector(goForward))
        configureButton(reloadButton, symbol: "arrow.clockwise", identifier: "BrowserReloadButton", action: #selector(reloadOrStop))
        configureButton(pdfDownloadButton, symbol: "square.and.arrow.down", identifier: "BrowserPDFDownloadButton", action: #selector(downloadPDF))
        configureButton(pdfPrintButton, symbol: "printer", identifier: "BrowserPDFPrintButton", action: #selector(printPDF))
        configureButton(importButton, symbol: "square.and.arrow.down.on.square", identifier: "BrowserImportHintToolbarChip", action: #selector(showImportMenu))
        configureButton(overflowButton, symbol: "ellipsis", identifier: "BrowserOverflowMenu", action: #selector(showOverflowMenu))
        configureButton(focusModeButton, symbol: "keyboard", identifier: "BrowserFocusModeButton", action: #selector(toggleFocusMode))
        configureButton(screenshotButton, symbol: "camera", identifier: "BrowserScreenshotPageButton", action: #selector(captureScreenshot))
        configureButton(profileButton, symbol: "person.crop.circle", identifier: "BrowserProfileButton", action: #selector(showProfileMenu))
        configureButton(themeButton, symbol: browserThemeMode.iconName, identifier: "BrowserThemeModeButton", action: #selector(showThemeMenu))
        configureButton(
            developerToolsButton,
            symbol: BrowserDevToolsButtonDebugSettings.iconOption().rawValue,
            identifier: "BrowserToggleDevToolsButton",
            action: #selector(toggleDeveloperTools)
        )

        let reloadMenu = NSMenu()
        reloadMenu.addItem(withTitle: String(localized: "browser.reload", defaultValue: "Reload"), action: #selector(reloadFromMenu), keyEquivalent: "")
        reloadMenu.addItem(withTitle: String(localized: "menu.view.hardRefresh", defaultValue: "Hard Refresh"), action: #selector(hardReloadFromMenu), keyEquivalent: "")
        reloadMenu.items.forEach { $0.target = self }
        reloadButton.menu = reloadMenu

        [backButton, forwardButton, reloadButton, pdfDownloadButton, pdfPrintButton, downloadsButton]
            .forEach(navigationStack.addArrangedSubview)
        [importButton, overflowButton, focusModeButton, designModeButton, screenshotButton, profileButton, themeButton, developerToolsButton]
            .forEach(accessoryStack.addArrangedSubview)

        secureBadgeView.imageScaling = .scaleProportionallyDown
        secureBadgeView.contentTintColor = .secondaryLabelColor
        secureBadgeView.translatesAutoresizingMaskIntoConstraints = false
        omnibarHost.field.translatesAutoresizingMaskIntoConstraints = false
        omnibarInteractionView.panelId = panel.id
        omnibarInteractionView.translatesAutoresizingMaskIntoConstraints = false
        omnibarPillView.addSubview(secureBadgeView)
        omnibarPillView.addSubview(omnibarHost.field)
        omnibarPillView.addSubview(omnibarInteractionView)

        [toolbarView, contentContainer, flashRing].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            rootView.addSubview($0)
        }
        [navigationStack, omnibarPillView, accessoryStack].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            toolbarView.addSubview($0)
        }
        [webHost.view, placeholderView, recoveryOverlay].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            contentContainer.addSubview($0)
        }

        webHost.view.setAccessibilityIdentifier("BrowserWebViewSurface")
        contentContainer.setAccessibilityIdentifier("BrowserPanelContent.\(panel.id.uuidString)")
        configureRecoveryOverlay()

        toolbarHeightConstraint = toolbarView.heightAnchor.constraint(equalToConstant: 34)
        NSLayoutConstraint.activate([
            toolbarView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            toolbarView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            toolbarView.topAnchor.constraint(equalTo: rootView.topAnchor),
            toolbarHeightConstraint,
            contentContainer.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: toolbarView.bottomAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            flashRing.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            flashRing.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            flashRing.topAnchor.constraint(equalTo: rootView.topAnchor),
            flashRing.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            navigationStack.leadingAnchor.constraint(equalTo: toolbarView.leadingAnchor, constant: 8),
            navigationStack.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),
            omnibarPillView.leadingAnchor.constraint(equalTo: navigationStack.trailingAnchor, constant: 8),
            omnibarPillView.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),
            accessoryStack.leadingAnchor.constraint(equalTo: omnibarPillView.trailingAnchor, constant: 8),
            accessoryStack.trailingAnchor.constraint(equalTo: toolbarView.trailingAnchor, constant: -8),
            accessoryStack.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),
            omnibarPillView.heightAnchor.constraint(equalToConstant: 26),

            secureBadgeView.leadingAnchor.constraint(equalTo: omnibarPillView.leadingAnchor, constant: 8),
            secureBadgeView.centerYAnchor.constraint(equalTo: omnibarPillView.centerYAnchor),
            secureBadgeView.widthAnchor.constraint(equalToConstant: 12),
            secureBadgeView.heightAnchor.constraint(equalToConstant: 12),
            omnibarHost.field.leadingAnchor.constraint(equalTo: secureBadgeView.trailingAnchor, constant: 4),
            omnibarHost.field.trailingAnchor.constraint(equalTo: omnibarPillView.trailingAnchor, constant: -8),
            omnibarHost.field.centerYAnchor.constraint(equalTo: omnibarPillView.centerYAnchor),
            omnibarHost.field.heightAnchor.constraint(equalToConstant: 18),
            omnibarInteractionView.leadingAnchor.constraint(equalTo: omnibarPillView.leadingAnchor),
            omnibarInteractionView.trailingAnchor.constraint(equalTo: omnibarPillView.trailingAnchor),
            omnibarInteractionView.topAnchor.constraint(equalTo: omnibarPillView.topAnchor),
            omnibarInteractionView.bottomAnchor.constraint(equalTo: omnibarPillView.bottomAnchor),
        ])

        for hostedView in [webHost.view, placeholderView, recoveryOverlay] {
            NSLayoutConstraint.activate([
                hostedView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
                hostedView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
                hostedView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
                hostedView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            ])
        }
    }

    private func configureRecoveryOverlay() {
        recoveryOverlay.wantsLayer = true
        recoveryButton.title = String(localized: "browser.error.reload", defaultValue: "Reload")
        recoveryButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: recoveryButton.title)
        recoveryButton.bezelStyle = .rounded
        recoveryButton.target = self
        recoveryButton.action = #selector(recoverWebContent)
        recoveryButton.setAccessibilityIdentifier("BrowserWebContentRecoveryButton")
        recoveryButton.translatesAutoresizingMaskIntoConstraints = false
        recoveryOverlay.addSubview(recoveryButton)
        NSLayoutConstraint.activate([
            recoveryButton.centerXAnchor.constraint(equalTo: recoveryOverlay.centerXAnchor),
            recoveryButton.centerYAnchor.constraint(equalTo: recoveryOverlay.centerYAnchor),
        ])
    }

    private func configureButton(
        _ button: BrowserToolbarButton,
        symbol: String,
        identifier: String,
        action: Selector
    ) {
        button.target = self
        button.action = action
        button.setAccessibilityIdentifier(identifier)
        button.update(symbol: symbol, pointSize: metrics.accessoryIconFontSize, hitSize: metrics.buttonIconSize)
    }

    private func startObserving() {
        panelCancellable = panel.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.handlePanelModelChange()
            }
        }
        historyCancellable = panel.historyStore.$entries.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.addressBarFocused else { return }
                self.refreshSuggestions()
            }
        }
        observe(.webViewDidReceiveClick) { [weak self] notification in
            self?.handleWebViewClick(notification)
        }
        observe(.browserDidBlurAddressBar) { [weak self] notification in
            guard let self, notification.object as? UUID == self.panel.id, self.addressBarFocused else { return }
            self.setAddressBarFocused(false, reason: "notification.externalBlur")
        }
        observe(.browserMoveOmnibarSelection) { [weak self] notification in
            guard let self,
                  notification.object as? UUID == self.panel.id,
                  let delta = notification.userInfo?["delta"] as? Int,
                  delta != 0,
                  self.canHandleOmnibarSuggestionInteraction() else { return }
            self.applyOmnibarEffects(omnibarReduce(state: &self.omnibarState, event: .moveSelection(delta: delta)))
            self.refreshInlineCompletion()
            self.render()
        }
        observe(.ghosttyConfigDidReload) { [weak self] _ in
            guard let self else { return }
            self.tabBarFontSize = GhosttyConfig.load(
                globalFontMagnificationPercent: GlobalFontMagnification.storedPercent
            ).surfaceTabBarFontSize
            self.render()
        }
        observe(.ghosttyDefaultBackgroundDidChange) { [weak self] _ in
            self?.render()
        }
        observe(.systemAppearanceDidChange) { [weak self] _ in
            self?.render()
        }
        observe(.commandPaletteVisibilityDidChange) { [weak self] _ in
            self?.applyPendingAddressBarFocusRequestIfNeeded()
        }
        observe(UserDefaults.didChangeNotification) { [weak self] _ in
            self?.render()
        }
    }

    private func observe(
        _ name: Notification.Name,
        handler: @escaping @MainActor (Notification) -> Void
    ) {
        notificationTasks.append(Task { @MainActor in
            for await notification in NotificationCenter.default.notifications(named: name) {
                guard !Task.isCancelled else { return }
                handler(notification)
            }
        })
    }

    private func scheduleRender() {
        guard renderTask == nil, !isTornDown else { return }
        renderTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.renderTask = nil
            self.render()
        }
    }

    private func handlePanelModelChange() {
        guard !isTornDown else { return }
        if lastURL != panel.currentURL {
            lastURL = panel.currentURL
            handleCurrentURLChange()
        }
        if lastShouldRenderWebView != panel.shouldRenderWebView {
            lastShouldRenderWebView = panel.shouldRenderWebView
        }
        if lastFocusFlashToken != panel.focusFlashToken {
            lastFocusFlashToken = panel.focusFlashToken
            flashRing.triggerFlash(reason: .navigation)
        }
        if lastProfileID != panel.profileID {
            lastProfileID = panel.profileID
            panel.historyStore.loadIfNeeded()
            if addressBarFocused { refreshSuggestions() }
        }
        if lastOmnibarVisible != panel.isOmnibarVisible {
            lastOmnibarVisible = panel.isOmnibarVisible
            if !panel.isOmnibarVisible {
                hideSuggestions()
                setAddressBarFocused(false, reason: "omnibar.hidden")
            } else {
                applyPendingAddressBarFocusRequestIfNeeded()
            }
        }
        scheduleRender()
    }

    private func handleAppearIfNeeded() {
        guard !didAppear else {
            render()
            return
        }
        didAppear = true
        startSuggestionConsumer()
        panel.noteWebViewVisibility(
            configuration.isVisibleInUI && isCurrentPaneOwner,
            reason: "nativeView.appear"
        )
        panel.refreshAppearanceDrivenColors()
        panel.setBrowserThemeMode(browserThemeMode)
        panel.historyStore.loadIfNeeded()
        syncURLFromPanel()
        applyPendingAddressBarFocusRequestIfNeeded()
        autoFocusOmnibarIfBlank()
        syncWebViewResponderPolicy()
        render()
    }

    private func render() {
        guard isViewLoaded, !isTornDown else { return }
        let currentMetrics = metrics
        let toolbarHeight = max(currentMetrics.buttonHitSize, currentMetrics.buttonIconSize) + 8
        toolbarHeightConstraint.constant = panel.isOmnibarVisible ? toolbarHeight : 0
        toolbarView.isHidden = !panel.isOmnibarVisible
        toolbarView.layer?.backgroundColor = chromeBackgroundColor.cgColor
        placeholderView.layer?.backgroundColor = chromeBackgroundColor.cgColor
        omnibarPillView.layer?.backgroundColor = omnibarBackgroundColor.cgColor
        omnibarPillView.layer?.borderWidth = addressBarFocused ? 1 : 0
        omnibarPillView.layer?.borderColor = cmuxAccentNSColor().cgColor

        let secure = panel.currentURL?.scheme == "https"
        secureBadgeView.isHidden = !secure
        secureBadgeView.image = secure
            ? NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: currentMetrics.secureBadgeFontSize, weight: .regular)
            )
            : nil

        updateNavigationButtons(metrics: currentMetrics)
        updateAccessoryButtons(metrics: currentMetrics)
        omnibarHost.update(omnibarConfiguration)
        omnibarInteractionView.panelId = panel.id
        omnibarInteractionView.window?.invalidateCursorRects(for: omnibarInteractionView)

        webHost.view.isHidden = !panel.shouldRenderWebView
        placeholderView.isHidden = panel.shouldRenderWebView
        recoveryOverlay.isHidden = !panel.hasRecoverableWebContentTermination
        recoveryOverlay.layer?.backgroundColor = chromeBackgroundColor.withAlphaComponent(0.92).cgColor
        updateLocalSearchOverlay()
        rootView.needsLayout = true
        rootView.layoutSubtreeIfNeeded()
        updateCompactChrome()
        updateBrowserHost()
        updateLocalSuggestions()
    }

    private func updateNavigationButtons(metrics: BrowserChromeMetrics) {
        backButton.update(symbol: "chevron.left", pointSize: metrics.navigationIconFontSize, hitSize: metrics.buttonHitSize)
        backButton.isEnabled = panel.canGoBack
        backButton.alphaValue = panel.canGoBack ? 1 : 0.4
        backButton.toolTip = String(localized: "browser.goBack", defaultValue: "Go Back")
        forwardButton.update(symbol: "chevron.right", pointSize: metrics.navigationIconFontSize, hitSize: metrics.buttonHitSize)
        forwardButton.isEnabled = panel.canGoForward
        forwardButton.alphaValue = panel.canGoForward ? 1 : 0.4
        forwardButton.toolTip = String(localized: "browser.goForward", defaultValue: "Go Forward")
        reloadButton.update(
            symbol: panel.isLoading ? "xmark" : "arrow.clockwise",
            pointSize: metrics.navigationIconFontSize,
            hitSize: metrics.buttonHitSize
        )
        reloadButton.toolTip = panel.isLoading
            ? String(localized: "browser.stop", defaultValue: "Stop")
            : String(localized: "browser.reload", defaultValue: "Reload")

        let showsPDF = panel.renderedPDFDocumentURL != nil
        pdfDownloadButton.isHidden = !showsPDF
        pdfPrintButton.isHidden = !showsPDF
        pdfDownloadButton.update(symbol: "square.and.arrow.down", pointSize: metrics.navigationIconFontSize, hitSize: metrics.buttonHitSize)
        pdfPrintButton.update(symbol: "printer", pointSize: metrics.navigationIconFontSize, hitSize: metrics.buttonHitSize)
        pdfDownloadButton.toolTip = String(localized: "browser.pdf.download", defaultValue: "Download PDF")
        pdfPrintButton.toolTip = String(localized: "browser.pdf.print", defaultValue: "Print PDF")

        let showsDownloads = panel.isDownloading || !panel.recentDownloads.isEmpty
        downloadsButton.isHidden = !showsDownloads
        if showsDownloads {
            downloadsButton.update(
                downloads: panel.recentDownloads,
                isDownloading: panel.isDownloading,
                iconPointSize: metrics.navigationIconFontSize,
                hitSize: metrics.buttonHitSize,
                onOpen: { [weak panel] in panel?.openDownload($0) },
                onReveal: { [weak panel] in panel?.revealDownloadInFinder($0) },
                onClear: { [weak panel] in panel?.clearRecentDownloads() }
            )
        }
    }

    private func updateAccessoryButtons(metrics: BrowserChromeMetrics) {
        let hitSize = metrics.buttonIconSize
        let pointSize = metrics.accessoryIconFontSize
        let color = BrowserDevToolsButtonDebugSettings.colorOption().nsColor
        for button in [importButton, overflowButton, focusModeButton, screenshotButton, profileButton, themeButton, developerToolsButton] {
            button.contentTintColor = color
        }
        focusModeButton.update(symbol: "keyboard", pointSize: pointSize, hitSize: hitSize)
        focusModeButton.contentTintColor = panel.isBrowserFocusModeActive ? .systemOrange : color
        focusModeButton.isEnabled = panel.canToggleBrowserFocusMode
        focusModeButton.alphaValue = panel.canToggleBrowserFocusMode ? 1 : 0.4
        focusModeButton.toolTip = browserFocusModeButtonHelp
        designModeButton.update(
            controller: panel.designModeController,
            iconPointSize: pointSize,
            hitSize: hitSize,
            inactiveColor: color,
            onToggle: { [weak panel] in
                guard let panel else { return false }
                return await panel.toggleDesignMode(reason: "toolbar")
            }
        )
        screenshotButton.update(
            symbol: screenshotPageCopied ? "checkmark" : "camera",
            pointSize: pointSize,
            hitSize: hitSize
        )
        screenshotButton.contentTintColor = screenshotPageCopied ? .systemGreen : color
        screenshotButton.isEnabled = panel.shouldRenderWebView && !screenshotCaptureInProgress
        screenshotButton.alphaValue = panel.shouldRenderWebView ? 1 : 0.4
        screenshotButton.toolTip = screenshotPageCopied
            ? String(localized: "browser.screenshotPage.copied.help", defaultValue: "Screenshot copied to clipboard")
            : String(localized: "browser.screenshotPage.copy.help", defaultValue: "Screenshot Page to Clipboard")
        profileButton.update(symbol: "person.crop.circle", pointSize: pointSize, hitSize: hitSize)
        profileButton.toolTip = String(
            format: String(localized: "browser.profile.buttonHelp", defaultValue: "Browser Profile: %@"),
            panel.profileDisplayName
        )
        themeButton.update(symbol: browserThemeMode.iconName, pointSize: pointSize, hitSize: hitSize)
        themeButton.toolTip = String(
            format: String(localized: "browser.theme.buttonHelp", defaultValue: "Browser Theme: %@"),
            browserThemeMode.displayName
        )
        developerToolsButton.update(
            symbol: BrowserDevToolsButtonDebugSettings.iconOption().rawValue,
            pointSize: pointSize,
            hitSize: hitSize
        )
        let devToolsTitle = String(localized: "browser.toggleDevTools", defaultValue: "Toggle Developer Tools")
        developerToolsButton.toolTip = "\(devToolsTitle) (\(KeyboardShortcutSettings.shortcut(for: .toggleBrowserDeveloperTools).displayString))"
        overflowButton.update(symbol: "ellipsis", pointSize: pointSize, hitSize: hitSize)
        overflowButton.toolTip = String(localized: "browser.moreActions", defaultValue: "More Actions")
        importButton.update(symbol: "square.and.arrow.down.on.square", pointSize: pointSize, hitSize: hitSize)
        importButton.toolTip = String(localized: "browser.import.hint.toolbar.help", defaultValue: "Import browser data")
        importButton.isHidden = !shouldShowToolbarImportHint
    }

    private func updateCompactChrome() {
        guard isViewLoaded else { return }
        let compact = toolbarView.bounds.width > 0 && toolbarView.bounds.width < 420
        overflowButton.isHidden = !compact
        focusModeButton.isHidden = compact
        designModeButton.isHidden = compact
        screenshotButton.isHidden = compact
        developerToolsButton.isHidden = compact
    }

    private var shouldShowToolbarImportHint: Bool {
        guard panel.isShowingNewTabPage else { return false }
        let defaults = UserDefaults.standard
        let presentation = BrowserImportHintPresentation(
            variant: BrowserImportHintSettings.variant(for: defaults.string(forKey: BrowserImportHintSettings.variantKey)),
            showOnBlankTabs: defaults.object(forKey: BrowserImportHintSettings.showOnBlankTabsKey) as? Bool
                ?? BrowserImportHintSettings.defaultShowOnBlankTabs,
            isDismissed: defaults.object(forKey: BrowserImportHintSettings.dismissedKey) as? Bool
                ?? BrowserImportHintSettings.defaultDismissed
        )
        return presentation.blankTabPlacement == .toolbarChip
    }

    private var omnibarConfiguration: OmnibarTextFieldNativeConfiguration {
        OmnibarTextFieldNativeConfiguration(
            panelId: panel.id,
            fontSize: metrics.omnibarFontSize,
            text: omnibarState.buffer,
            isFocused: addressBarFocused,
            selectAllRequestId: omnibarSelectAllRequestId,
            inlineCompletion: inlineCompletion,
            placeholder: String(localized: "browser.addressBar.placeholder", defaultValue: "Search or enter URL"),
            onTextChange: { [weak self] text in
                guard let self else { return }
                let effects = omnibarReduce(state: &self.omnibarState, event: .bufferChanged(text))
                self.applyOmnibarEffects(effects)
                if !effects.shouldClearInlineCompletion { self.refreshInlineCompletion() }
                self.render()
            },
            onFocusChange: { [weak self] focused in
                self?.setAddressBarFocused(focused, reason: "nativeField.focusChange")
            },
            onTap: { [weak self] in self?.handleOmnibarTap() },
            onSubmit: { [weak self] in self?.handleOmnibarSubmit(liveField: $0) },
            onEscape: { [weak self] in self?.handleOmnibarEscape() },
            onFieldLostFocus: { [weak self] in
                self?.setAddressBarFocused(false, reason: "nativeField.lostFocus")
            },
            onMoveSelection: { [weak self] delta in
                guard let self, self.canHandleOmnibarSuggestionInteraction() else { return }
                self.applyOmnibarEffects(omnibarReduce(state: &self.omnibarState, event: .moveSelection(delta: delta)))
                self.refreshInlineCompletion()
                self.render()
            },
            onDeleteSelectedSuggestion: { [weak self] in self?.deleteSelectedSuggestionIfPossible() },
            onAcceptInlineCompletion: { [weak self] in self?.acceptInlineCompletion() },
            onDeleteBackwardWithInlineSelection: { [weak self] in self?.handleInlineBackspace() },
            onClearTypedPrefixWithInlineSelection: { [weak self] in self?.handleInlineClearTypedPrefix() },
            onDeleteWordBackwardWithInlineSelection: { [weak self] in self?.handleInlineDeleteWordBackward() },
            onSelectionChanged: { [weak self] range, marked in
                self?.handleSelectionChange(range: range, hasMarkedText: marked)
            },
            shouldSuppressWebViewFocus: { [weak panel] in panel?.shouldSuppressWebViewFocus() ?? false }
        )
    }

    private func updateBrowserHost() {
        guard isViewLoaded else { return }
        let localInline = configuration.canvasInlineBrowserHosting
        webHost.update(BrowserWebViewNativeConfiguration(
            panel: panel,
            paneId: configuration.paneID,
            shouldAttachWebView: configuration.isVisibleInUI && isCurrentPaneOwner && !localInline,
            useLocalInlineHosting: localInline,
            shouldFocusWebView: configuration.isFocused && !addressBarFocused,
            isPanelFocused: configuration.isFocused,
            portalZPriority: configuration.portalPriority,
            paneDropZone: configuration.paneDropZone,
            paneOwnershipOverride: configuration.paneOwnershipOverride,
            searchOverlay: portalSearchOverlayConfiguration,
            designComposer: BrowserPortalDesignComposerConfiguration(
                panelId: panel.id,
                controller: panel.designModeController
            ),
            omnibarSuggestions: portalSuggestionsConfiguration,
            paneTopChromeHeight: panel.isOmnibarVisible ? toolbarHeightConstraint.constant : 0
        ))
    }

    private var portalSearchOverlayConfiguration: BrowserPortalSearchOverlayConfiguration? {
        guard panel.shouldRenderWebView, let searchState = panel.searchState else { return nil }
        return BrowserPortalSearchOverlayConfiguration(
            panelId: panel.id,
            searchState: searchState,
            focusRequestGeneration: panel.searchFocusRequestGeneration,
            canApplyFocusRequest: { [weak self] generation in
                self?.canApplyFindFocusRequest(generation) ?? false
            },
            onNext: { [weak panel] in panel?.findNext() },
            onPrevious: { [weak panel] in panel?.findPrevious() },
            onClose: { [weak panel] in panel?.hideFind() },
            onFieldDidFocus: { [weak panel] in panel?.noteFindFieldFocused() }
        )
    }

    private var portalSuggestionsConfiguration: BrowserPortalOmnibarSuggestionsConfiguration? {
        guard panel.shouldRenderWebView,
              addressBarFocused,
              !omnibarHasMarkedText,
              !omnibarState.suggestions.isEmpty else { return nil }
        let frame = omnibarPillView.convert(omnibarPillView.bounds, to: rootView)
        let popupFrame = CGRect(
            x: frame.minX,
            y: max(0, frame.maxY + 3 - toolbarHeightConstraint.constant),
            width: frame.width,
            height: OmnibarSuggestionsView.popupHeight(for: omnibarState.suggestions)
        )
        return makeSuggestionsConfiguration(frame: popupFrame)
    }

    private func makeSuggestionsConfiguration(
        frame: CGRect
    ) -> BrowserPortalOmnibarSuggestionsConfiguration {
        BrowserPortalOmnibarSuggestionsConfiguration(
            panelId: panel.id,
            popupFrame: frame,
            colorScheme: chromeIsDark ? .dark : .light,
            engineName: searchConfiguration.displayName,
            items: omnibarState.suggestions,
            selectedIndex: omnibarState.selectedSuggestionIndex,
            isLoadingRemoteSuggestions: isLoadingRemoteSuggestions,
            searchSuggestionsEnabled: remoteSuggestionsEnabled,
            onCommit: { [weak self] in self?.commitSuggestion($0) },
            onHighlight: { [weak self] index in
                guard let self else { return }
                self.applyOmnibarEffects(omnibarReduce(state: &self.omnibarState, event: .highlightIndex(index)))
                self.render()
            }
        )
    }

    private func updateLocalSuggestions() {
        guard isViewLoaded else { return }
        guard !panel.shouldRenderWebView,
              addressBarFocused,
              !omnibarHasMarkedText,
              !omnibarState.suggestions.isEmpty else {
            localSuggestionsHost?.removeFromSuperview()
            localSuggestionsHost = nil
            return
        }
        let frame = omnibarPillView.convert(omnibarPillView.bounds, to: rootView)
        let config = makeSuggestionsConfiguration(frame: CGRect(
            x: frame.minX,
            y: frame.maxY + 3,
            width: frame.width,
            height: OmnibarSuggestionsView.popupHeight(for: omnibarState.suggestions)
        ))
        if let localSuggestionsHost {
            localSuggestionsHost.update(configuration: config)
        } else {
            let host = BrowserPortalOmnibarSuggestionsHostingView(configuration: config)
            host.translatesAutoresizingMaskIntoConstraints = false
            rootView.addSubview(host, positioned: .above, relativeTo: flashRing)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
                host.topAnchor.constraint(equalTo: rootView.topAnchor),
                host.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            ])
            localSuggestionsHost = host
        }
    }

    private func updateLocalSearchOverlay() {
        guard !panel.shouldRenderWebView, let searchState = panel.searchState else {
            localSearchOverlay?.removeFromSuperview()
            localSearchOverlay = nil
            return
        }
        let update: (BrowserSearchOverlay) -> Void = { [weak self] overlay in
            guard let self else { return }
            overlay.update(
                panelId: self.panel.id,
                searchState: searchState,
                focusRequestGeneration: self.panel.searchFocusRequestGeneration,
                canApplyFocusRequest: { [weak self] in self?.canApplyFindFocusRequest($0) ?? false },
                onNext: { [weak self] in self?.panel.findNext() },
                onPrevious: { [weak self] in self?.panel.findPrevious() },
                onClose: { [weak self] in self?.panel.hideFind() },
                onFieldDidFocus: { [weak self] in self?.panel.noteFindFieldFocused() }
            )
        }
        if let localSearchOverlay {
            update(localSearchOverlay)
            return
        }
        let overlay = BrowserSearchOverlay(
            panelId: panel.id,
            searchState: searchState,
            focusRequestGeneration: panel.searchFocusRequestGeneration,
            canApplyFocusRequest: { [weak self] in self?.canApplyFindFocusRequest($0) ?? false },
            onNext: { [weak panel] in panel?.findNext() },
            onPrevious: { [weak panel] in panel?.findPrevious() },
            onClose: { [weak panel] in panel?.hideFind() },
            onFieldDidFocus: { [weak panel] in panel?.noteFindFieldFocused() }
        )
        overlay.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(overlay, positioned: .above, relativeTo: recoveryOverlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: 8),
            overlay.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor, constant: -8),
        ])
        localSearchOverlay = overlay
    }

    private func handleWebViewClick(_ notification: Notification) {
        guard let webView = notification.object as? CmuxWebView, webView === panel.webView else { return }
        if addressBarFocused {
            setAddressBarFocused(false, reason: "webView.click")
        }
        if !configuration.isFocused {
            configuration.onRequestPanelFocus()
        }
    }

    private func handlePanelVisibilityChange(_ visible: Bool) {
        let effective = visible && isCurrentPaneOwner
        panel.noteWebViewVisibility(effective, reason: effective ? "nativeView.visible" : "nativeView.hidden")
        if visible {
            panel.cancelPendingDeveloperToolsVisibilityLossCheck()
        } else {
            panel.scheduleDeveloperToolsVisibilityLossCheck()
        }
    }

    private func handlePanelFocusChange(_ focused: Bool) {
        if focused {
            applyPendingAddressBarFocusRequestIfNeeded()
            autoFocusOmnibarIfBlank()
        } else {
            panel.invalidateAddressBarPageFocusRestoreAttempts()
            panel.clearBrowserFocusMode(reason: "nativePanel.unfocused")
            hideSuggestions()
            setAddressBarFocused(false, reason: "nativePanel.unfocused")
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, self.configuration.isVisibleInUI else { return }
                self.panel.scheduleDeveloperToolsVisibilityLossCheck()
            }
        }
        syncWebViewResponderPolicy()
    }

    private func handleCurrentURLChange() {
        let addressWasEmpty = omnibarState.buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        syncURLFromPanel()
        if addressBarFocused,
           !panel.shouldSuppressWebViewFocus(),
           addressWasEmpty,
           panel.preferredURLStringForOmnibar() != nil {
            setAddressBarFocused(false, reason: "panel.urlLoaded")
        }
        panel.resetReactGrabState(preserveRoundTrip: true, reason: "panel.urlChanged")
    }

    private func setAddressBarFocused(
        _ focused: Bool,
        reason: String,
        focusGainedSelectionIntent: BrowserAddressBarFocusSelectionIntent = .preserveFieldEditorSelection
    ) {
        if focused == addressBarFocused {
            if focused { panel.noteAddressBarFocused() }
            render()
            return
        }
        if focused {
            pendingFocusGainedSelectionIntent = focusGainedSelectionIntent
        } else {
            pendingFocusGainedSelectionIntent = .preserveFieldEditorSelection
        }
        addressBarFocused = focused
        let url = panel.preferredURLStringForOmnibar() ?? ""
        if focused {
            let selectionIntent = pendingFocusGainedSelectionIntent
            pendingFocusGainedSelectionIntent = .preserveFieldEditorSelection
            panel.beginSuppressWebViewFocusForAddressBar()
            panel.noteAddressBarFocused()
            NotificationCenter.default.post(name: .browserDidFocusAddressBar, object: panel.id)
            if !configuration.isFocused { configuration.onRequestPanelFocus() }
            applyOmnibarEffects(omnibarReduce(
                state: &omnibarState,
                event: .focusGained(currentURLString: url, shouldSelectAll: selectionIntent.shouldSelectAll)
            ))
            refreshInlineCompletion()
        } else {
            panel.endSuppressWebViewFocusForAddressBar()
            NotificationCenter.default.post(name: .browserDidBlurAddressBar, object: panel.id)
            let event: OmnibarEvent = suppressNextFocusLostRevert
                ? .focusLostPreserveBuffer(currentURLString: url)
                : .focusLostRevertBuffer(currentURLString: url)
            suppressNextFocusLostRevert = false
            applyOmnibarEffects(omnibarReduce(state: &omnibarState, event: event))
            inlineCompletion = nil
        }
        syncWebViewResponderPolicy()
        render()
#if DEBUG
        cmuxDebugLog("browser.focus.native panel=\(panel.id.uuidString.prefix(5)) focused=\(focused ? 1 : 0) reason=\(reason)")
#endif
    }

    private func handleOmnibarTap() {
        let wasFocused = addressBarFocused
        if !wasFocused { setAddressBarFocused(true, reason: "omnibar.tap") }
        if !configuration.isFocused && wasFocused { configuration.onRequestPanelFocus() }
    }

    private func handleOmnibarSubmit(liveField: OmnibarLiveFieldSnapshot?) {
        switch omnibarSubmitDecision(
            liveField: liveField,
            state: omnibarState,
            inlineCompletion: inlineCompletion,
            canInteractWithSuggestions: canHandleOmnibarSuggestionInteraction()
        ) {
        case .commitSelectedSuggestion:
            commitSelectedSuggestion()
        case .navigate(let text):
            if text != omnibarState.buffer {
                applyOmnibarEffects(omnibarReduce(state: &omnibarState, event: .bufferChanged(text)))
            }
            panel.navigateSmart(text)
            hideSuggestions()
            suppressNextFocusLostRevert = true
            setAddressBarFocused(false, reason: "omnibar.submit")
        }
    }

    private func handleOmnibarEscape() {
        guard addressBarFocused else { return }
        if inlineCompletion != nil {
            inlineCompletion = nil
            render()
            return
        }
        applyOmnibarEffects(omnibarReduce(state: &omnibarState, event: .escape))
        refreshInlineCompletion()
        render()
    }

    private func handleSelectionChange(range: NSRange, hasMarkedText: Bool) {
        let beganComposition = !omnibarHasMarkedText && hasMarkedText
        omnibarSelectionRange = range
        omnibarHasMarkedText = hasMarkedText
        if beganComposition { hideSuggestions() } else { refreshInlineCompletion() }
    }

    private func syncURLFromPanel() {
        applyOmnibarEffects(omnibarReduce(
            state: &omnibarState,
            event: .panelURLChanged(currentURLString: panel.preferredURLStringForOmnibar() ?? "")
        ))
    }

    private func autoFocusOmnibarIfBlank() {
        guard panel.isOmnibarVisible,
              configuration.isFocused,
              !addressBarFocused,
              !isCommandPaletteVisible(),
              !panel.shouldSuppressOmnibarAutofocus(),
              !panel.webView.isLoading,
              panel.preferredURLStringForOmnibar() == nil else { return }
        setAddressBarFocused(true, reason: "autoFocus.blank")
    }

    private func applyPendingAddressBarFocusRequestIfNeeded() {
        guard let requestID = panel.pendingAddressBarFocusRequestId,
              !isCommandPaletteVisible(),
              lastHandledAddressBarFocusRequestId != requestID else { return }
        lastHandledAddressBarFocusRequestId = requestID
        let selectionIntent = panel.pendingAddressBarFocusSelectionIntent
        panel.beginSuppressWebViewFocusForAddressBar()
        if addressBarFocused {
            applyOmnibarEffects(omnibarReduce(
                state: &omnibarState,
                event: .focusReasserted(
                    shouldSelectAll: browserOmnibarShouldSelectAllOnFocusReassertion(
                        selectionIntent: selectionIntent
                    )
                )
            ))
            refreshInlineCompletion()
            render()
        } else {
            setAddressBarFocused(true, reason: "request.apply", focusGainedSelectionIntent: selectionIntent)
        }
        panel.acknowledgeAddressBarFocusRequest(requestID)
    }

    private func isCommandPaletteVisible() -> Bool {
        guard let app = AppDelegate.shared else { return false }
        if let window = panel.webView.window, app.isCommandPaletteVisible(for: window) { return true }
        if let manager = app.tabManagerFor(tabId: panel.workspaceId),
           let windowID = app.windowId(for: manager),
           let window = app.mainWindow(for: windowID),
           app.isCommandPaletteVisible(for: window) { return true }
        return false
    }

    private func isPanelFocusedInModel() -> Bool {
        if let override = configuration.paneOwnershipOverride {
            return override && configuration.isFocused
        }
        guard let app = AppDelegate.shared,
              let manager = app.tabManagerFor(tabId: panel.workspaceId),
              manager.selectedTabId == panel.workspaceId,
              let workspace = manager.tabs.first(where: { $0.id == panel.workspaceId }) else { return false }
        return workspace.focusedPanelId == panel.id
    }

    private func canApplyFindFocusRequest(_ generation: UInt64) -> Bool {
        isPanelFocusedInModel() && panel.canApplySearchFocusRequest(generation)
    }

    private func syncWebViewResponderPolicy() {
        guard let webView = panel.webView as? CmuxWebView else { return }
        webView.allowsFirstResponderAcquisition = configuration.isFocused && !panel.shouldSuppressWebViewFocus()
    }

    private func canHandleOmnibarSuggestionInteraction() -> Bool {
        let focused = addressBarFocused ||
            AppDelegate.shared?.focusedBrowserAddressBarPanelId() == panel.id ||
            browserOmnibarField(panelId: panel.id, in: panel.webView.window ?? view.window)?.currentEditor() != nil
        return focused && !omnibarHasMarkedText && !omnibarState.suggestions.isEmpty
    }

    private func startSuggestionConsumer() {
        guard suggestionConsumerTask == nil else { return }
        suggestionConsumerTask = Task { @MainActor [weak self, suggestionScheduler] in
            for await generation in suggestionScheduler.refreshStream {
                guard !Task.isCancelled else { return }
                guard suggestionScheduler.shouldProcessRefresh(generation) else { continue }
                self?.refreshSuggestions()
            }
        }
    }

    private func hideSuggestions() {
        suggestionScheduler.cancelPendingRefresh()
        suggestionTask?.cancel()
        suggestionTask = nil
        isLoadingRemoteSuggestions = false
        applyOmnibarEffects(omnibarReduce(state: &omnibarState, event: .suggestionsUpdated([])))
        inlineCompletion = nil
        updateLocalSuggestions()
    }

    private func refreshSuggestions() {
        suggestionTask?.cancel()
        suggestionTask = nil
        isLoadingRemoteSuggestions = false
        guard addressBarFocused, !omnibarHasMarkedText else {
            applyOmnibarEffects(omnibarReduce(state: &omnibarState, event: .suggestionsUpdated([])))
            render()
            return
        }
        let query = omnibarState.buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        let history = query.isEmpty
            ? panel.historyStore.recentSuggestions(limit: 12)
            : panel.historyStore.suggestions(for: query, limit: 12)
        let openTabs = query.isEmpty ? [] : matchingOpenTabSuggestions(for: query, limit: 12)
        let singleCharacter = omnibarSingleCharacterQuery(for: query) != nil
        let engine = searchConfiguration.remoteSuggestionsEngine
        let allowsRemote = remoteSuggestionsEnabled && engine != nil
        if !allowsRemote {
            latestRemoteSuggestionQuery = ""
            latestRemoteSuggestions = []
        }
        let staleRemote = query.isEmpty || singleCharacter ? [] : staleOmnibarRemoteSuggestionsForDisplay(
            query: query,
            previousRemoteQuery: latestRemoteSuggestionQuery,
            previousRemoteSuggestions: latestRemoteSuggestions,
            allowsRemoteSuggestions: allowsRemote
        )
        let local = buildOmnibarSuggestions(
            query: query,
            engineName: searchConfiguration.displayName,
            historyEntries: history,
            openTabMatches: openTabs,
            remoteQueries: staleRemote,
            resolvedURL: query.isEmpty ? nil : panel.resolveNavigableURL(from: query),
            limit: 8
        )
        applyOmnibarEffects(omnibarReduce(state: &omnibarState, event: .suggestionsUpdated(local)))
        refreshInlineCompletion()
        render()
        guard !query.isEmpty,
              !singleCharacter,
              remoteSuggestionsEnabled,
              omnibarInputIntent(for: query) != .urlLike,
              let engine else { return }
        isLoadingRemoteSuggestions = true
        suggestionTask = Task { @MainActor [weak self] in
            let remote = await BrowserSearchSuggestionService.shared.suggestions(engine: engine, query: query)
            guard let self, !Task.isCancelled,
                  self.addressBarFocused,
                  !self.omnibarHasMarkedText,
                  self.omnibarState.buffer.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
            self.latestRemoteSuggestionQuery = query
            self.latestRemoteSuggestions = remote
            let merged = buildOmnibarSuggestions(
                query: query,
                engineName: self.searchConfiguration.displayName,
                historyEntries: self.panel.historyStore.suggestions(for: query, limit: 12),
                openTabMatches: self.matchingOpenTabSuggestions(for: query, limit: 12),
                remoteQueries: remote,
                resolvedURL: self.panel.resolveNavigableURL(from: query),
                limit: 8
            )
            self.applyOmnibarEffects(omnibarReduce(state: &self.omnibarState, event: .suggestionsUpdated(merged)))
            self.refreshInlineCompletion()
            self.isLoadingRemoteSuggestions = false
            self.render()
        }
    }

    private func matchingOpenTabSuggestions(for query: String, limit: Int) -> [OmnibarOpenTabMatch] {
        guard !query.isEmpty, limit > 0 else { return [] }
        let current = BrowserOpenTabSuggestionSnapshot(
            workspaceId: panel.workspaceId,
            panelId: panel.id,
            url: panel.preferredURLStringForOmnibar(),
            title: panel.pageTitle
        )
        let manager = AppDelegate.shared?.tabManagerFor(tabId: panel.workspaceId) ?? AppDelegate.shared?.tabManager
        return manager?.matchingOpenBrowserTabSuggestions(
            for: query,
            currentWorkspaceId: panel.workspaceId,
            currentPanelId: panel.id,
            currentPanelSnapshot: current,
            includeCurrentPanelForSingleCharacterQuery: omnibarSingleCharacterQuery(for: query) != nil,
            limit: limit
        ) ?? []
    }

    private func applyOmnibarEffects(_ effects: OmnibarEffects) {
        if effects.shouldCancelPendingSuggestionRefresh {
            suggestionScheduler.cancelPendingRefresh()
            suggestionTask?.cancel()
            suggestionTask = nil
            isLoadingRemoteSuggestions = false
        }
        if effects.shouldClearInlineCompletion { inlineCompletion = nil }
        if effects.shouldRefreshSuggestions { suggestionScheduler.scheduleRefresh() }
        if effects.shouldSelectAll { omnibarSelectAllRequestId &+= 1 }
        if effects.shouldBlurToWebView {
            hideSuggestions()
            panel.endSuppressWebViewFocusForAddressBar()
            setAddressBarFocused(false, reason: "effects.blurToWebView")
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self,
                      let window = self.panel.webView.window,
                      !self.panel.webView.isHiddenOrHasHiddenAncestor,
                      self.isPanelFocusedInModel(),
                      self.panel.searchState == nil else {
                    NotificationCenter.default.post(name: .browserDidExitAddressBar, object: self?.panel.id)
                    return
                }
                self.panel.clearWebViewFocusSuppression()
                if window.makeFirstResponder(self.panel.webView) {
                    self.panel.noteWebViewFocused()
                }
                NotificationCenter.default.post(name: .browserDidExitAddressBar, object: self.panel.id)
            }
        }
    }

    private func refreshInlineCompletion() {
        inlineCompletion = omnibarInlineCompletionForDisplay(
            typedText: omnibarState.buffer,
            suggestions: omnibarState.suggestions,
            isFocused: addressBarFocused,
            selectionRange: omnibarSelectionRange,
            hasMarkedText: omnibarHasMarkedText
        )
    }

    private func acceptInlineCompletion() {
        guard let completion = inlineCompletion else { return }
        applyOmnibarEffects(omnibarReduce(state: &omnibarState, event: .bufferChanged(completion.displayText)))
        inlineCompletion = nil
        render()
    }

    private func handleInlineBackspace() {
        guard let completion = inlineCompletion, !completion.typedText.isEmpty else { return }
        let updated = String(completion.typedText.dropLast())
        let effects = omnibarReduce(state: &omnibarState, event: .bufferChanged(updated))
        applyOmnibarEffects(effects)
        omnibarSelectionRange = NSRange(location: updated.utf16.count, length: 0)
        if !effects.shouldClearInlineCompletion { refreshInlineCompletion() }
        render()
    }

    private func handleInlineClearTypedPrefix() {
        guard inlineCompletion != nil else { return }
        _ = omnibarReduce(state: &omnibarState, event: .bufferChanged(""))
        omnibarSelectionRange = NSRange(location: 0, length: 0)
        hideSuggestions()
        render()
    }

    private func handleInlineDeleteWordBackward() {
        guard let completion = inlineCompletion else { return }
        let updated = omnibarPrefixAfterDeletingTrailingWord(from: completion.typedText)
        _ = omnibarReduce(state: &omnibarState, event: .bufferChanged(updated))
        omnibarSelectionRange = NSRange(location: updated.utf16.count, length: 0)
        hideSuggestions()
        render()
    }

    private func deleteSelectedSuggestionIfPossible() {
        let index = omnibarState.selectedSuggestionIndex
        guard omnibarState.suggestions.indices.contains(index),
              case .history(let url, _) = omnibarState.suggestions[index].kind,
              panel.historyStore.removeHistoryEntry(urlString: url) else { return }
        refreshSuggestions()
    }

    private func commitSelectedSuggestion() {
        let index = omnibarState.selectedSuggestionIndex
        guard omnibarState.suggestions.indices.contains(index) else { return }
        commitSuggestion(omnibarState.suggestions[index])
    }

    private func commitSuggestion(_ suggestion: OmnibarSuggestion) {
        omnibarState.buffer = suggestion.completion
        omnibarState.isUserEditing = false
        switch suggestion.kind {
        case .switchToTab(let tabID, let panelID, _, _):
            AppDelegate.shared?.tabManager?.focusTab(tabID, surfaceId: panelID)
        default:
            panel.navigateSmart(suggestion.completion)
        }
        hideSuggestions()
        inlineCompletion = nil
        suppressNextFocusLostRevert = true
        setAddressBarFocused(false, reason: "suggestion.commit")
    }

    private var browserFocusModeButtonHelp: String {
        let format = String(localized: "browser.focusMode.helpWithShortcut.format", defaultValue: "%@ (%@)")
        if panel.isBrowserFocusModeActive {
            return String(
                format: format,
                String(localized: "browser.focusMode.exit.help", defaultValue: "Exit browser focus mode"),
                String(localized: "browser.focusMode.shortcutHint", defaultValue: "Esc Esc")
            )
        }
        let title = String(localized: "browser.focusMode.enter.help", defaultValue: "Enter browser focus mode")
        let shortcut = KeyboardShortcutSettings.shortcut(for: .toggleBrowserFocusMode)
        return shortcut.isUnbound ? title : String(format: format, title, shortcut.displayString)
    }

    private func showMenu(_ menu: NSMenu, from button: NSButton) {
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 2), in: button)
    }

    @objc private func goBack() { panel.goBack() }
    @objc private func goForward() { panel.goForward() }

    @objc private func reloadOrStop() {
        if panel.isLoading {
            panel.stopLoading()
        } else if !panel.recoverTerminatedWebContent(reason: "toolbarReload") {
            panel.reload()
        }
    }

    @objc private func reloadFromMenu() { panel.reload() }
    @objc private func hardReloadFromMenu() { panel.hardReload() }
    @objc private func downloadPDF() { panel.downloadRenderedPDFDocument() }
    @objc private func printPDF() { panel.printRenderedPDFDocument() }
    @objc private func recoverWebContent() { _ = panel.recoverTerminatedWebContent(reason: "overlayButton") }

    @objc private func toggleFocusMode() {
        if !panel.toggleBrowserFocusMode(reason: "toolbarButton", focusWebView: true) { NSSound.beep() }
        render()
    }

    @objc private func toggleDeveloperTools() {
        if !panel.toggleDeveloperTools() { NSSound.beep() }
    }

    @objc private func captureScreenshot() {
        guard !screenshotCaptureInProgress else { return }
        screenshotCaptureInProgress = true
        render()
        screenshotTask?.cancel()
        screenshotTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let copied = await self.panel.captureScreenshotPageToClipboard()
            self.screenshotCaptureInProgress = false
            guard copied, !Task.isCancelled else {
                self.render()
                return
            }
            self.screenshotPageCopied = true
            self.render()
            self.screenshotIndicatorTask?.cancel()
            self.screenshotIndicatorTask = Task { @MainActor [weak self] in
                try? await ContinuousClock().sleep(for: .milliseconds(1400))
                guard let self, !Task.isCancelled else { return }
                self.screenshotPageCopied = false
                self.render()
            }
        }
    }

    @objc private func showOverflowMenu() {
        let menu = NSMenu()
        menu.addItem(menuItem(
            title: panel.isBrowserFocusModeActive
                ? String(localized: "browser.focusMode.active", defaultValue: "Focus Mode")
                : String(localized: "browser.focusMode.enter", defaultValue: "Enter Focus Mode"),
            symbol: "keyboard",
            action: #selector(toggleFocusMode),
            enabled: panel.canToggleBrowserFocusMode
        ))
        menu.addItem(menuItem(
            title: String(localized: "browser.screenshotPage.copy.help", defaultValue: "Screenshot Page to Clipboard"),
            symbol: "camera",
            action: #selector(captureScreenshot),
            enabled: panel.shouldRenderWebView
        ))
        menu.addItem(menuItem(
            title: String(localized: "browser.designMode.title", defaultValue: "Design Mode"),
            symbol: "paintbrush.pointed",
            action: #selector(toggleDesignModeFromMenu),
            enabled: panel.designModeController.canToggle
        ))
        menu.addItem(menuItem(
            title: String(localized: "browser.toggleDevTools", defaultValue: "Toggle Developer Tools"),
            symbol: BrowserDevToolsButtonDebugSettings.iconOption().rawValue,
            action: #selector(toggleDeveloperTools),
            enabled: true
        ))
        showMenu(menu, from: overflowButton)
    }

    @objc private func toggleDesignModeFromMenu() {
        Task { @MainActor [weak panel] in
            _ = await panel?.toggleDesignMode(reason: "overflowMenu")
        }
    }

    @objc private func showProfileMenu() {
        let menu = NSMenu()
        let store = BrowserProfileStore.shared
        for profile in store.profiles {
            let item = NSMenuItem(title: profile.displayName, action: #selector(selectProfile(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = profile.id
            item.state = profile.id == panel.profileID ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(menuItem(title: String(localized: "browser.profile.new", defaultValue: "New Profile..."), action: #selector(createProfile)))
        menu.addItem(menuItem(title: String(localized: "menu.view.importFromBrowser", defaultValue: "Import Browser Data…"), action: #selector(importBrowserData)))
        if store.canRenameProfile(id: panel.profileID) {
            menu.addItem(menuItem(title: String(localized: "browser.profile.rename", defaultValue: "Rename Current Profile..."), action: #selector(renameProfile)))
        }
        showMenu(menu, from: profileButton)
    }

    @objc private func selectProfile(_ sender: NSMenuItem) {
        guard let profileID = sender.representedObject as? UUID else { return }
        let applied = panel.profileID == profileID || panel.switchToProfile(profileID)
        if applied { owningWorkspace?.setPreferredBrowserProfileID(profileID) }
    }

    @objc private func createProfile() {
        presentProfilePrompt(mode: .create)
    }

    @objc private func renameProfile() {
        presentProfilePrompt(mode: .rename)
    }

    private enum ProfilePromptMode { case create, rename }

    private func presentProfilePrompt(mode: ProfilePromptMode) {
        let store = BrowserProfileStore.shared
        let current = store.profileDefinition(id: panel.profileID)
        let alert = NSAlert()
        switch mode {
        case .create:
            alert.messageText = String(localized: "browser.profile.new.title", defaultValue: "New Browser Profile")
            alert.informativeText = String(localized: "browser.profile.new.message", defaultValue: "Create a separate browser profile for cookies, history, and local storage.")
        case .rename:
            guard let current, store.canRenameProfile(id: current.id) else { return }
            alert.messageText = String(localized: "browser.profile.rename.title", defaultValue: "Rename Browser Profile")
            alert.informativeText = String(localized: "browser.profile.rename.message", defaultValue: "Choose a new name for this browser profile.")
        }
        let input = NSTextField(string: mode == .rename ? current?.displayName ?? "" : "")
        input.placeholderString = String(localized: "browser.profile.new.placeholder", defaultValue: "Profile name")
        input.frame = NSRect(x: 0, y: 0, width: 260, height: 22)
        alert.accessoryView = input
        alert.addButton(withTitle: mode == .create
            ? String(localized: "common.create", defaultValue: "Create")
            : String(localized: "common.rename", defaultValue: "Rename"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        switch mode {
        case .create:
            if let profile = store.createProfile(named: input.stringValue), panel.switchToProfile(profile.id) {
                owningWorkspace?.setPreferredBrowserProfileID(profile.id)
            }
        case .rename:
            if let current { _ = store.renameProfile(id: current.id, to: input.stringValue) }
        }
    }

    @objc private func showThemeMenu() {
        let menu = NSMenu()
        for mode in BrowserThemeMode.allCases {
            let item = NSMenuItem(title: mode.displayName, action: #selector(selectTheme(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = mode == browserThemeMode ? .on : .off
            item.image = NSImage(systemSymbolName: mode.iconName, accessibilityDescription: mode.displayName)
            menu.addItem(item)
        }
        showMenu(menu, from: themeButton)
    }

    @objc private func selectTheme(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = BrowserThemeMode(rawValue: raw) else { return }
        UserDefaults.standard.set(mode.rawValue, forKey: BrowserThemeSettings.modeKey)
        panel.setBrowserThemeMode(mode)
        render()
    }

    @objc private func showImportMenu() {
        let menu = NSMenu()
        menu.addItem(menuItem(title: String(localized: "browser.import.hint.import", defaultValue: "Import…"), action: #selector(importBrowserData)))
        menu.addItem(menuItem(title: String(localized: "browser.import.hint.settings", defaultValue: "Browser Settings"), action: #selector(openBrowserSettings)))
        menu.addItem(menuItem(title: String(localized: "browser.import.hint.dismiss", defaultValue: "Hide Hint"), action: #selector(dismissImportHint)))
        showMenu(menu, from: importButton)
    }

    @objc private func importBrowserData() {
        BrowserDataImportCoordinator.shared.presentImportDialog(defaultDestinationProfileID: panel.profileID)
    }

    @objc private func openBrowserSettings() {
        AppDelegate.presentPreferencesWindow(navigationTarget: .browserImport)
    }

    @objc private func dismissImportHint() {
        UserDefaults.standard.set(false, forKey: BrowserImportHintSettings.showOnBlankTabsKey)
        UserDefaults.standard.set(true, forKey: BrowserImportHintSettings.dismissedKey)
        render()
    }

    private func menuItem(
        title: String,
        symbol: String? = nil,
        action: Selector,
        enabled: Bool = true
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) }
        return item
    }
}

@MainActor
private final class BrowserToolbarButton: NSButton {
    private var trackingAreaToken: NSTrackingArea?
    private var hitSize: CGFloat = 22
    private var isHovered = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        imagePosition = .imageOnly
        isBordered = false
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 8
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: hitSize, height: hitSize)
    }

    func update(symbol: String, pointSize: CGFloat, hitSize: CGFloat) {
        self.hitSize = hitSize
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        )
        invalidateIntrinsicContentSize()
        updateBackground()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaToken { removeTrackingArea(trackingAreaToken) }
        let token = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(token)
        trackingAreaToken = token
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateBackground()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateBackground()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    private func updateBackground() {
        layer?.backgroundColor = isHovered && isEnabled
            ? NSColor.labelColor.withAlphaComponent(0.08).cgColor
            : NSColor.clear.cgColor
    }
}
