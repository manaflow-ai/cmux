import AppKit
import CmuxFoundation
import Combine
import WebKit

/// Native panel controller for markdown preview and text editing.
///
/// The renderer remains panel-owned so pane moves preserve the WKWebView and
/// its WebContent process. AppKit owns the surrounding chrome and lifecycle.
@MainActor
final class MarkdownPanelNativeViewController: NSViewController, PanelContentControllerUpdating {
    private var configuration: PanelContentConfiguration
    private weak var panel: MarkdownPanel?
    private var panelCancellable: AnyCancellable?
    private var defaultsTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var copyConfirmationTask: Task<Void, Never>?
    private var externalApplicationTask: Task<Void, Never>?
    private var externalApplications: [FileExternalOpenApplication] = []
    private var resolvedExternalFileURL: URL?
    private var lastFocusFlashToken = 0

    private let header = MarkdownPanelHeaderView()
    private let divider = NSBox()
    private let contentContainer = NSView()
    private let renderer = MarkdownWebRendererNativeView()
    private let unavailableView = PanelFileUnavailableNativeView(
        title: String(localized: "markdown.fileUnavailable.title", defaultValue: "File unavailable"),
        message: String(
            localized: "markdown.fileUnavailable.message",
            defaultValue: "The file may have been moved or deleted."
        )
    )
    private let flashRing = WorkspaceAttentionFlashRingNativeView(frame: .zero)
    private var textEditorController: FilePreviewTextEditorController?

    init(configuration: PanelContentConfiguration) {
        self.configuration = configuration
        super.init(nibName: nil, bundle: nil)
        update(configuration: configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true

        header.translatesAutoresizingMaskIntoConstraints = false
        divider.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        renderer.translatesAutoresizingMaskIntoConstraints = false
        unavailableView.translatesAutoresizingMaskIntoConstraints = false
        flashRing.translatesAutoresizingMaskIntoConstraints = false

        divider.boxType = .separator
        contentContainer.wantsLayer = true
        root.addSubview(header)
        root.addSubview(divider)
        root.addSubview(contentContainer)
        contentContainer.addSubview(renderer)
        contentContainer.addSubview(unavailableView)
        root.addSubview(flashRing)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.heightAnchor.constraint(equalToConstant: 30),
            divider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            divider.topAnchor.constraint(equalTo: header.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: divider.bottomAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            renderer.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            renderer.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            renderer.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            renderer.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            unavailableView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            unavailableView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            unavailableView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            unavailableView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            flashRing.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            flashRing.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            flashRing.topAnchor.constraint(equalTo: root.topAnchor),
            flashRing.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    func update(configuration: PanelContentConfiguration) {
        self.configuration = configuration
        loadViewIfNeeded()
        guard let panel = configuration.panel as? MarkdownPanel else { return }
        observe(panel)
        refresh(panel: panel)
    }

    func teardownPanelContent() {
        panelCancellable = nil
        defaultsTask?.cancel()
        defaultsTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        copyConfirmationTask?.cancel()
        copyConfirmationTask = nil
        externalApplicationTask?.cancel()
        externalApplicationTask = nil
        header.teardown()
        renderer.teardown()
        textEditorController?.panel = nil
        textEditorController = nil
        panel = nil
    }

    isolated deinit {
        defaultsTask?.cancel()
        refreshTask?.cancel()
        copyConfirmationTask?.cancel()
        externalApplicationTask?.cancel()
    }

    private func observe(_ panel: MarkdownPanel) {
        guard self.panel !== panel else { return }
        panelCancellable = panel.objectWillChange.sink { [weak self] in
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.scheduleRefresh()
            }
        }
        defaultsTask?.cancel()
        defaultsTask = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: UserDefaults.didChangeNotification,
                object: UserDefaults.standard
            ) {
                guard !Task.isCancelled else { return }
                self?.scheduleRefresh()
            }
        }
        self.panel = panel
        lastFocusFlashToken = panel.focusFlashToken
        resolveExternalApplications(for: panel)
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self, let panel = self.panel else { return }
            self.refresh(panel: panel)
        }
    }

    private func refresh(panel: MarkdownPanel) {
        let appearance = configuration.appearance
        let backgroundColor = appearance.contentBackgroundColor
        view.layer?.backgroundColor = backgroundColor.cgColor
        contentContainer.layer?.backgroundColor = backgroundColor.cgColor
        view.appearance = NSAppearance(named: appearance.backgroundColor.isLightColor ? .aqua : .darkAqua)

        header.update(
            panel: panel,
            foregroundColor: appearance.foregroundColor,
            onRevert: { [weak panel] in _ = panel?.loadTextContent() },
            onSave: { [weak panel] in _ = panel?.saveTextContent() },
            onRefresh: { [weak panel] in panel?.reloadFromDisk() },
            onToggleMode: { [weak panel] in
                guard let panel else { return }
                panel.setDisplayMode(panel.displayMode == .preview ? .text : .preview)
            },
            onCopyMarkdown: { [weak self] in self?.copyAsMarkdown() },
            onCopyHTML: { [weak self] in self?.copyAsHTML() },
            onOpenExternally: { [weak self] button in self?.presentExternalMenu(relativeTo: button) }
        )

        renderer.update(
            markdown: panel.content,
            theme: MarkdownWebTheme.resolve(backgroundColor: appearance.backgroundColor),
            backgroundColor: backgroundColor,
            panelID: panel.id,
            workspaceID: panel.workspaceId,
            filePath: panel.filePath,
            fontSize: panel.fontSize,
            fontFamily: panel.fontFamily,
            maxContentWidth: panel.maxContentWidth,
            session: panel.rendererSession,
            onRequestPanelFocus: configuration.onRequestPanelFocus
        )

        if textEditorController == nil {
            let editor = FilePreviewTextEditorController(
                panel: panel,
                isVisibleInUI: false,
                themeBackgroundColor: backgroundColor,
                themeForegroundColor: appearance.foregroundColor,
                drawsBackground: appearance.drawsContentBackground,
                wordWrap: FilePreviewWordWrapSettings.isEnabled()
            )
            let scrollView = editor.scrollView
            scrollView.translatesAutoresizingMaskIntoConstraints = false
            contentContainer.addSubview(scrollView, positioned: .above, relativeTo: renderer)
            NSLayoutConstraint.activate([
                scrollView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
                scrollView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
                scrollView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            ])
            textEditorController = editor
        }

        let showsTextEditor = !panel.isFileUnavailable && panel.displayMode == .text
        textEditorController?.configure(
            panel: panel,
            isVisibleInUI: configuration.isVisibleInUI && showsTextEditor,
            themeBackgroundColor: backgroundColor,
            themeForegroundColor: appearance.foregroundColor,
            drawsBackground: appearance.drawsContentBackground,
            wordWrap: FilePreviewWordWrapSettings.isEnabled()
        )
        renderer.isHidden = panel.isFileUnavailable || panel.displayMode != .preview
        textEditorController?.scrollView.isHidden = !showsTextEditor
        unavailableView.isHidden = !panel.isFileUnavailable
        unavailableView.update(filePath: panel.filePath)

        if showsTextEditor, configuration.isFocused {
            panel.retryPendingFocus()
        }
        if lastFocusFlashToken != panel.focusFlashToken {
            lastFocusFlashToken = panel.focusFlashToken
            flashRing.triggerFlash(reason: .navigation)
        }
    }

    private func copyAsMarkdown() {
        guard let panel else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(panel.content, forType: .string)
        showCopyConfirmation(.markdown)
    }

    private func copyAsHTML() {
        guard let panel else { return }
        copyConfirmationTask?.cancel()
        copyConfirmationTask = Task { @MainActor [weak self, weak panel] in
            guard let panel,
                  let html = await panel.rendererSession.renderedHTML(markdown: panel.content),
                  !Task.isCancelled else { return }
            let text = await panel.rendererSession.renderedText() ?? panel.content
            guard !Task.isCancelled else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(html, forType: .html)
            pasteboard.setString(text, forType: .string)
            self?.showCopyConfirmation(.html)
        }
    }

    private func showCopyConfirmation(_ confirmation: MarkdownCopyConfirmation) {
        copyConfirmationTask?.cancel()
        header.setCopyConfirmation(confirmation.label)
        copyConfirmationTask = Task { @MainActor [weak self] in
            do {
                try await ContinuousClock().sleep(for: .milliseconds(1_600))
            } catch {
                return
            }
            self?.header.setCopyConfirmation(nil)
        }
    }

    private func resolveExternalApplications(for panel: MarkdownPanel) {
        let fileURL = URL(fileURLWithPath: panel.filePath)
        guard resolvedExternalFileURL != fileURL else { return }
        resolvedExternalFileURL = fileURL
        externalApplications = []
        externalApplicationTask?.cancel()
        externalApplicationTask = Task { @MainActor [weak self] in
            let applications = await Task.detached(priority: .userInitiated) {
                FileExternalOpenApplicationResolver.live.applications(for: fileURL)
            }.value
            guard !Task.isCancelled else { return }
            self?.externalApplications = applications
        }
    }

    private func presentExternalMenu(relativeTo button: NSButton) {
        guard let panel, !panel.isFileUnavailable else { return }
        let fileURL = URL(fileURLWithPath: panel.filePath)
        let applications = externalApplications.isEmpty
            ? FileExternalOpenApplicationResolver.live.applications(for: fileURL)
            : externalApplications
        let primary = applications.first(where: \.isDefault) ?? applications.first
        let others = applications.filter { $0.id != primary?.id }
        let menu = FileExternalOpenMenuFactory.makeMenu(
            fileURL: fileURL,
            primaryApplication: primary,
            otherApplications: others
        )
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY), in: button)
    }
}

private enum MarkdownCopyConfirmation {
    case markdown
    case html

    var label: String {
        switch self {
        case .markdown:
            String(localized: "markdown.copyConfirm.markdown", defaultValue: "Copied as Markdown")
        case .html:
            String(localized: "markdown.copyConfirm.html", defaultValue: "Copied as HTML")
        }
    }
}

@MainActor
private final class MarkdownPanelHeaderView: NSView {
    private let iconView = NSImageView()
    private let pathLabel = NSTextField(labelWithString: "")
    private let controls = NSStackView()
    private let confirmationLabel = NSTextField(labelWithString: "")
    private let typographyButton = MarkdownTypographyButtonView(frame: .zero)
    private let revertButton = PanelHeaderNativeButton(
        systemName: "arrow.counterclockwise",
        label: String(localized: "markdown.toolbar.revert", defaultValue: "Revert")
    )
    private let saveButton = PanelHeaderNativeButton(
        systemName: "square.and.arrow.down",
        label: String(localized: "markdown.toolbar.save", defaultValue: "Save")
    )
    private let refreshButton = PanelHeaderNativeButton(
        systemName: "arrow.clockwise",
        label: String(localized: "filePreview.refresh", defaultValue: "Refresh")
    )
    private let modeButton = PanelHeaderNativeButton(systemName: "doc.plaintext", label: "")
    private let copyMarkdownButton = PanelHeaderNativeButton(
        systemName: "doc.on.doc",
        label: String(localized: "markdown.toolbar.copyMarkdown", defaultValue: "Copy as Markdown")
    )
    private let copyHTMLButton = PanelHeaderNativeButton(
        systemName: "chevron.left.forwardslash.chevron.right",
        label: String(localized: "markdown.toolbar.copyHTML", defaultValue: "Copy as HTML")
    )
    private let externalButton = PanelHeaderNativeButton(systemName: "square.and.arrow.up", label: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        controls.translatesAutoresizingMaskIntoConstraints = false
        typographyButton.translatesAutoresizingMaskIntoConstraints = false

        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = .secondaryLabelColor
        pathLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.maximumNumberOfLines = 1
        pathLabel.isSelectable = true
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        confirmationLabel.font = .systemFont(ofSize: 11, weight: .medium)
        confirmationLabel.textColor = .secondaryLabelColor
        confirmationLabel.lineBreakMode = .byTruncatingTail
        confirmationLabel.isHidden = true

        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 4
        [
            confirmationLabel,
            revertButton,
            saveButton,
            typographyButton,
            refreshButton,
            modeButton,
            copyMarkdownButton,
            copyHTMLButton,
            externalButton,
        ].forEach(controls.addArrangedSubview)

        addSubview(iconView)
        addSubview(pathLabel)
        addSubview(controls)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            pathLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            pathLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            pathLabel.trailingAnchor.constraint(lessThanOrEqualTo: controls.leadingAnchor, constant: -8),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            controls.centerYAnchor.constraint(equalTo: centerYAnchor),
            typographyButton.widthAnchor.constraint(equalToConstant: 20),
            typographyButton.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        panel: MarkdownPanel,
        foregroundColor: NSColor,
        onRevert: @escaping () -> Void,
        onSave: @escaping () -> Void,
        onRefresh: @escaping () -> Void,
        onToggleMode: @escaping () -> Void,
        onCopyMarkdown: @escaping () -> Void,
        onCopyHTML: @escaping () -> Void,
        onOpenExternally: @escaping (NSButton) -> Void
    ) {
        let iconName = panel.displayIcon ?? "doc.richtext"
        iconView.image = RenderableSystemSymbol.configuredAppKitImage(
            systemName: iconName,
            pointSize: 16,
            weight: .regular
        )
        pathLabel.stringValue = panel.filePath
        pathLabel.textColor = foregroundColor.withAlphaComponent(0.68)
        typographyButton.update(panel: panel)

        let isText = panel.displayMode == .text
        revertButton.isHidden = !isText
        saveButton.isHidden = !isText
        typographyButton.isHidden = isText
        refreshButton.isHidden = isText
        revertButton.isEnabled = panel.isDirty
        saveButton.isEnabled = panel.isDirty && !panel.isSaving
        externalButton.isEnabled = !panel.isFileUnavailable

        let modeIcon = isText ? "eye" : "doc.plaintext"
        let modeLabel = isText
            ? String(localized: "markdown.mode.showPreview", defaultValue: "Show Preview")
            : String(localized: "markdown.mode.showTextEdit", defaultValue: "Show TextEdit")
        modeButton.update(systemName: modeIcon, label: modeLabel)
        let externalLabel = FileExternalOpenText.openExternally
        externalButton.update(systemName: "square.and.arrow.up", label: externalLabel)

        revertButton.actionClosure = onRevert
        saveButton.actionClosure = onSave
        refreshButton.actionClosure = onRefresh
        modeButton.actionClosure = onToggleMode
        copyMarkdownButton.actionClosure = onCopyMarkdown
        copyHTMLButton.actionClosure = onCopyHTML
        externalButton.actionClosure = { [weak externalButton] in
            guard let externalButton else { return }
            onOpenExternally(externalButton)
        }
    }

    func setCopyConfirmation(_ confirmation: String?) {
        confirmationLabel.stringValue = confirmation ?? ""
        confirmationLabel.isHidden = confirmation == nil
    }

    func teardown() {
        typographyButton.teardown()
        [revertButton, saveButton, refreshButton, modeButton, copyMarkdownButton, copyHTMLButton, externalButton]
            .forEach { $0.actionClosure = nil }
    }
}

@MainActor
final class PanelHeaderNativeButton: NSButton {
    var actionClosure: (() -> Void)?
    private var trackingAreaReference: NSTrackingArea?
    private var isPointerInside = false

    init(systemName: String, label: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        title = ""
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        isBordered = false
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 5
        contentTintColor = .secondaryLabelColor
        target = self
        action = #selector(invoke)
        widthAnchor.constraint(equalToConstant: 20).isActive = true
        heightAnchor.constraint(equalToConstant: 20).isActive = true
        update(systemName: systemName, label: label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(trackingArea)
        trackingAreaReference = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        updateBackground()
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        updateBackground()
    }

    override var isHighlighted: Bool {
        didSet { updateBackground() }
    }

    func update(systemName: String, label: String) {
        image = RenderableSystemSymbol.configuredAppKitImage(
            systemName: systemName,
            pointSize: 13,
            weight: .regular
        )
        toolTip = label
        setAccessibilityLabel(label)
    }

    private func updateBackground() {
        let opacity: CGFloat = isHighlighted ? 0.14 : (isPointerInside && isEnabled ? 0.08 : 0)
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(opacity).cgColor
    }

    @objc private func invoke() {
        actionClosure?()
    }
}

@MainActor
final class PanelFileUnavailableNativeView: NSView {
    private let pathLabel = NSTextField(wrappingLabelWithString: "")

    init(title titleText: String, message messageText: String) {
        super.init(frame: .zero)

        let icon = NSImageView()
        icon.image = RenderableSystemSymbol.configuredAppKitImage(
            systemName: "doc.questionmark",
            pointSize: 40,
            weight: .regular
        )
        icon.contentTintColor = .secondaryLabelColor

        let title = NSTextField(labelWithString: titleText)
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        title.alignment = .center

        pathLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.alignment = .center
        pathLabel.isSelectable = true
        pathLabel.maximumNumberOfLines = 0

        let message = NSTextField(wrappingLabelWithString: messageText)
        message.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        message.textColor = .secondaryLabelColor
        message.alignment = .center

        let stack = NSStackView(views: [icon, title, pathLabel, message])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            pathLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 640),
            icon.widthAnchor.constraint(equalToConstant: 44),
            icon.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(filePath: String) {
        pathLabel.stringValue = filePath
    }
}

@MainActor
private final class MarkdownWebRendererNativeView: NSView {
    private weak var installedWebView: WKWebView?
    private weak var coordinator: MarkdownWebRendererCore.Coordinator?

    func update(
        markdown: String,
        theme: MarkdownWebTheme,
        backgroundColor: NSColor,
        panelID: UUID,
        workspaceID: UUID,
        filePath: String,
        fontSize: Double,
        fontFamily: String,
        maxContentWidth: Double,
        session: MarkdownRendererSession,
        onRequestPanelFocus: @escaping () -> Void
    ) {
        let coordinator = session.coordinator(
            panelId: panelID,
            workspaceId: workspaceID,
            filePath: filePath
        )
        let isNewWebView = coordinator.webView == nil
        let webView = coordinator.webView ?? makeWebView(coordinator: coordinator)
        if installedWebView !== webView || webView.superview !== self {
            webView.removeFromSuperview()
            webView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(webView)
            NSLayoutConstraint.activate([
                webView.leadingAnchor.constraint(equalTo: leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: trailingAnchor),
                webView.topAnchor.constraint(equalTo: topAnchor),
                webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            installedWebView = webView
        }
        self.coordinator = coordinator
        configure(
            webView,
            coordinator: coordinator,
            theme: theme,
            backgroundColor: backgroundColor,
            fontSize: fontSize,
            fontFamily: fontFamily,
            maxContentWidth: maxContentWidth,
            onRequestPanelFocus: onRequestPanelFocus
        )
        if isNewWebView {
            coordinator.loadShell(theme: theme, initialMarkdown: markdown)
        } else {
            coordinator.update(markdown: markdown, theme: theme)
        }
    }

    func teardown() {
        guard let webView = installedWebView as? MarkdownWebView else { return }
        webView.onPointerDown = nil
        installedWebView = nil
        coordinator = nil
    }

    private func makeWebView(coordinator: MarkdownWebRendererCore.Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = false
        configuration.userContentController.add(
            WeakMarkdownScriptMessageHandler(coordinator),
            name: "cmuxLib"
        )
        configuration.setURLSchemeHandler(
            coordinator,
            forURLScheme: MarkdownWebRendererCore.localImageURLScheme
        )
        configuration.setURLSchemeHandler(
            coordinator,
            forURLScheme: MarkdownWebRendererCore.remoteImageURLScheme
        )
        let webView = MarkdownWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        if #available(macOS 13.3, *) {
#if DEBUG
            webView.isInspectable = true
#else
            webView.isInspectable = false
#endif
        }
        coordinator.webView = webView
        return webView
    }

    private func configure(
        _ webView: WKWebView,
        coordinator: MarkdownWebRendererCore.Coordinator,
        theme: MarkdownWebTheme,
        backgroundColor: NSColor,
        fontSize: Double,
        fontFamily: String,
        maxContentWidth: Double,
        onRequestPanelFocus: @escaping () -> Void
    ) {
        if let markdownView = webView as? MarkdownWebView {
            markdownView.onPointerDown = onRequestPanelFocus
            markdownView.onLeaveWindow = { [weak coordinator] in
                coordinator?.handleViewLeftWindow()
            }
            markdownView.onReenterWindow = { [weak coordinator] in
                coordinator?.handleViewReenteredWindow()
            }
        }
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        webView.underPageBackgroundColor = backgroundColor
        webView.wantsLayer = true
        webView.layer?.backgroundColor = backgroundColor.cgColor
        webView.layer?.isOpaque = backgroundColor.alphaComponent >= 0.999
        let appearanceName: NSAppearance.Name = theme.isDark ? .darkAqua : .aqua
        if webView.appearance?.name != appearanceName {
            webView.appearance = NSAppearance(named: appearanceName)
        }
        coordinator.setFontSize(fontSize)
        coordinator.setFontFamily(fontFamily)
        coordinator.setMaxContentWidth(maxContentWidth)
    }
}
