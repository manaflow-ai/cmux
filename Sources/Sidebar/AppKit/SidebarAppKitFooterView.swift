import AppKit
import CmuxFoundation
import CmuxUpdater
@preconcurrency import Sparkle

/// Fixed native footer shell for the AppKit workspace sidebar.
///
/// Buttons are created once and remain in a stable hierarchy. Callers inject
/// behavior and update the value presentation; this view owns no app models.
@MainActor
final class SidebarAppKitFooterView: NSView {
    struct Callbacks {
        let onHelpAction: (SidebarAppKitHelpMenuController.Action) -> Void
        let onOpenExtensionBrowser: (NSView) -> Void
        let onOpenPricing: () -> Void
        let onDismissPro: () -> Void
        let onCheckForUpdates: () -> Void
        let onCheckForUpdatesInCustomUI: () -> Void
        let onAttemptUpdate: () -> Void
        let updateLogPath: () -> String
        let onSendFeedback: () -> Void
    }

    struct Presentation: Equatable {
        let showsExtensionButton: Bool
        let showsProButton: Bool
        let proButtonTitle: String
        let showsUpdateButton: Bool
        let updateButtonTitle: String
        let showsShortcutDiscoveryButton: Bool
        let showsDevBuildBanner: Bool

        init(
            showsExtensionButton: Bool = false,
            showsProButton: Bool = false,
            proButtonTitle: String = String(
                localized: "sidebar.pro.badge",
                defaultValue: "Upgrade"
            ),
            showsUpdateButton: Bool = false,
            updateButtonTitle: String = String(
                localized: "command.checkForUpdates.title",
                defaultValue: "Check for Updates"
            ),
            showsShortcutDiscoveryButton: Bool = false,
            showsDevBuildBanner: Bool = false
        ) {
            self.showsExtensionButton = showsExtensionButton
            self.showsProButton = showsProButton
            self.proButtonTitle = proButtonTitle
            self.showsUpdateButton = showsUpdateButton
            self.updateButtonTitle = updateButtonTitle
            self.showsShortcutDiscoveryButton = showsShortcutDiscoveryButton
            self.showsDevBuildBanner = showsDevBuildBanner
        }
    }

    private enum Metrics {
        static let iconButtonSize: CGFloat = 22
        static let controlHeight: CGFloat = 22
        static let horizontalSpacing: CGFloat = 4
        static let verticalSpacing: CGFloat = 6
        static let leadingInset: CGFloat = 6
        static let trailingInset: CGFloat = 10
        static let verticalInset: CGFloat = 6
    }

    let helpButton: NSButton
    let proButton: NSButton
    let proDismissButton: NSButton
    let extensionButton: NSButton
    let updateButton: NSButton
    let shortcutDiscoveryButton: NSButton
    let devBuildBannerLabel: NSTextField

    private let callbacks: Callbacks
    private let helpMenuController: SidebarAppKitHelpMenuController
    private let shortcutMenuController = SidebarAppKitShortcutMenuController()
    private let proBadgeView: SidebarAppKitProBadgeView
    private let updatePopoverController: SidebarAppKitUpdatePopoverController
    private let buttonStack: NSStackView
    private let contentStack: NSStackView
    private var fontMagnificationObserver: GlobalFontMagnificationChangeObserver?
    private(set) var presentation: Presentation

    init(
        updateModel: UpdateStateModel,
        presentation: Presentation = Presentation(),
        callbacks: Callbacks
    ) {
        let helpTitle = String(localized: "sidebar.help.button", defaultValue: "Help")
        let extensionTitle = String(
            localized: "sidebar.extensions.browser.title",
            defaultValue: "Sidebar Extensions"
        )
        let helpButton = Self.makeIconButton(
            systemSymbolName: "questionmark.circle",
            accessibilityLabel: helpTitle,
            accessibilityIdentifier: "SidebarHelpMenuButton"
        )
        let extensionButton = Self.makeIconButton(
            systemSymbolName: "puzzlepiece.extension",
            accessibilityLabel: extensionTitle,
            accessibilityIdentifier: "SidebarExtensionMenuButton"
        )
        let proButton = Self.makeTextButton(accessibilityIdentifier: "SidebarProButton")
        let proDismissTitle = String(
            localized: "sidebar.pro.badge.dismiss",
            defaultValue: "Hide the Pro badge"
        )
        let proDismissButton = Self.makeIconButton(
            systemSymbolName: "xmark",
            accessibilityLabel: proDismissTitle,
            accessibilityIdentifier: "ProBadgeDismissButton"
        )
        proDismissButton.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: GlobalFontMagnification.scaledSize(8),
            weight: .bold
        )
        let proBadgeView = SidebarAppKitProBadgeView(
            primaryButton: proButton,
            dismissButton: proDismissButton
        )
        let updateButton = Self.makeTextButton(accessibilityIdentifier: "SidebarUpdateButton")
        let shortcutTitle = String(
            localized: "shortcutDiscovery.button.help",
            defaultValue: "Show all shortcuts"
        )
        let shortcutDiscoveryButton = Self.makeIconButton(
            systemSymbolName: "keyboard",
            accessibilityLabel: shortcutTitle,
            accessibilityIdentifier: "SidebarShortcutDiscoveryButton"
        )
        let devBuildBannerTitle = String(
            localized: "debug.devBuildBanner.title",
            defaultValue: "THIS IS A DEV BUILD"
        )
        let devBuildBannerLabel = NSTextField(labelWithString: devBuildBannerTitle)
        devBuildBannerLabel.translatesAutoresizingMaskIntoConstraints = false
        devBuildBannerLabel.font = GlobalFontMagnification.systemFont(
            ofSize: 11,
            weight: .semibold
        )
        devBuildBannerLabel.textColor = .systemRed
        devBuildBannerLabel.lineBreakMode = .byTruncatingTail
        devBuildBannerLabel.identifier = NSUserInterfaceItemIdentifier("SidebarDevBuildBanner")
        devBuildBannerLabel.setAccessibilityIdentifier("SidebarDevBuildBanner")
        devBuildBannerLabel.setAccessibilityLabel(devBuildBannerTitle)

        self.helpButton = helpButton
        self.proButton = proButton
        self.proDismissButton = proDismissButton
        self.extensionButton = extensionButton
        self.updateButton = updateButton
        self.shortcutDiscoveryButton = shortcutDiscoveryButton
        self.devBuildBannerLabel = devBuildBannerLabel
        self.callbacks = callbacks
        self.presentation = presentation
        self.proBadgeView = proBadgeView
        updatePopoverController = SidebarAppKitUpdatePopoverController(
            model: updateModel,
            actions: SidebarAppKitUpdatePopoverController.Actions(
                checkForUpdatesInCustomUI: callbacks.onCheckForUpdatesInCustomUI,
                attemptUpdate: callbacks.onAttemptUpdate,
                updateLogPath: callbacks.updateLogPath
            )
        )
        helpMenuController = SidebarAppKitHelpMenuController(
            callbacks: SidebarAppKitHelpMenuController.Callbacks(
                onHelpAction: callbacks.onHelpAction,
                onCheckForUpdates: callbacks.onCheckForUpdates,
                onSendFeedback: callbacks.onSendFeedback
            )
        )
        buttonStack = NSStackView(views: [
            helpButton,
            proBadgeView,
            extensionButton,
            updateButton,
            shortcutDiscoveryButton,
        ])
        contentStack = NSStackView(views: [buttonStack, devBuildBannerLabel])

        super.init(frame: .zero)
        configureHierarchy()
        configureActions()
        apply(presentation: presentation)
        fontMagnificationObserver = GlobalFontMagnificationChangeObserver { [weak self] in
            self?.refreshFontMagnification()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        let bannerHeight = presentation.showsDevBuildBanner
            ? Metrics.verticalSpacing + devBuildBannerLabel.intrinsicContentSize.height
            : 0
        return NSSize(
            width: NSView.noIntrinsicMetric,
            height: max(Metrics.controlHeight, buttonStack.fittingSize.height)
                + bannerHeight
                + (Metrics.verticalInset * 2)
        )
    }

    /// Updates titles and visibility without replacing any button or stack view.
    func apply(presentation: Presentation) {
        updatePopoverController.refresh(
            allowsPresentation: presentation.showsUpdateButton
        )
        guard self.presentation != presentation || proButton.title.isEmpty else { return }
        let bannerVisibilityChanged = self.presentation.showsDevBuildBanner
            != presentation.showsDevBuildBanner
        self.presentation = presentation

        extensionButton.isHidden = !presentation.showsExtensionButton
        proButton.title = presentation.proButtonTitle
        proButton.toolTip = presentation.proButtonTitle
        proButton.setAccessibilityLabel(presentation.proButtonTitle)
        proBadgeView.isHidden = !presentation.showsProButton
        if !presentation.showsProButton {
            proBadgeView.resetHover()
        }
        updateButton.title = presentation.updateButtonTitle
        updateButton.toolTip = presentation.updateButtonTitle
        updateButton.setAccessibilityLabel(presentation.updateButtonTitle)
        updateButton.isHidden = !presentation.showsUpdateButton
        shortcutDiscoveryButton.isHidden = !presentation.showsShortcutDiscoveryButton
        devBuildBannerLabel.isHidden = !presentation.showsDevBuildBanner
        if bannerVisibilityChanged {
            invalidateIntrinsicContentSize()
        }
    }

    private func configureHierarchy() {
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.distribution = .gravityAreas
        buttonStack.spacing = Metrics.horizontalSpacing
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.distribution = .fill
        contentStack.spacing = Metrics.verticalSpacing
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.leadingInset),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Metrics.trailingInset),
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.verticalInset),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.verticalInset),
            helpButton.widthAnchor.constraint(greaterThanOrEqualToConstant: Metrics.iconButtonSize),
            helpButton.heightAnchor.constraint(greaterThanOrEqualToConstant: Metrics.iconButtonSize),
            extensionButton.widthAnchor.constraint(greaterThanOrEqualToConstant: Metrics.iconButtonSize),
            extensionButton.heightAnchor.constraint(greaterThanOrEqualToConstant: Metrics.iconButtonSize),
            proBadgeView.heightAnchor.constraint(greaterThanOrEqualToConstant: Metrics.controlHeight),
            proButton.heightAnchor.constraint(greaterThanOrEqualToConstant: Metrics.controlHeight),
            proDismissButton.widthAnchor.constraint(greaterThanOrEqualToConstant: Metrics.iconButtonSize),
            proDismissButton.heightAnchor.constraint(greaterThanOrEqualToConstant: Metrics.iconButtonSize),
            updateButton.heightAnchor.constraint(greaterThanOrEqualToConstant: Metrics.controlHeight),
            shortcutDiscoveryButton.widthAnchor.constraint(greaterThanOrEqualToConstant: Metrics.iconButtonSize),
            shortcutDiscoveryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: Metrics.iconButtonSize),
        ])

        helpButton.setContentHuggingPriority(.required, for: .horizontal)
        extensionButton.setContentHuggingPriority(.required, for: .horizontal)
        proBadgeView.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        proButton.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        updateButton.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        shortcutDiscoveryButton.setContentHuggingPriority(.required, for: .horizontal)
    }

    private func configureActions() {
        helpButton.target = self
        helpButton.action = #selector(showHelpMenu(_:))
        extensionButton.target = self
        extensionButton.action = #selector(openExtensionBrowser(_:))
        proButton.target = self
        proButton.action = #selector(openPricing(_:))
        proDismissButton.target = self
        proDismissButton.action = #selector(dismissPro(_:))
        updateButton.target = self
        updateButton.action = #selector(showUpdate(_:))
        shortcutDiscoveryButton.target = self
        shortcutDiscoveryButton.action = #selector(showShortcutDiscovery(_:))
    }

    private static func makeIconButton(
        systemSymbolName: String,
        accessibilityLabel: String,
        accessibilityIdentifier: String
    ) -> NSButton {
        let button = NSButton(frame: .zero)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.title = ""
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.focusRingType = .none
        button.refusesFirstResponder = true
        button.setButtonType(.momentaryChange)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        let image = NSImage(
            systemSymbolName: systemSymbolName,
            accessibilityDescription: accessibilityLabel
        )
        button.image = image
        button.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: GlobalFontMagnification.scaledSize(12),
            weight: .medium
        )
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = accessibilityLabel
        button.identifier = NSUserInterfaceItemIdentifier(accessibilityIdentifier)
        button.setAccessibilityIdentifier(accessibilityIdentifier)
        button.setAccessibilityLabel(accessibilityLabel)
        button.setAccessibilityRole(.button)
        return button
    }

    private static func makeTextButton(accessibilityIdentifier: String) -> NSButton {
        let button = NSButton(title: "", target: nil, action: nil)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .roundRect
        button.controlSize = .small
        button.font = GlobalFontMagnification.systemFont(ofSize: 11, weight: .medium)
        button.focusRingType = .none
        button.refusesFirstResponder = true
        button.setButtonType(.momentaryPushIn)
        button.identifier = NSUserInterfaceItemIdentifier(accessibilityIdentifier)
        button.setAccessibilityIdentifier(accessibilityIdentifier)
        button.setAccessibilityRole(.button)
        return button
    }

    private func refreshFontMagnification() {
        let symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: GlobalFontMagnification.scaledSize(12),
            weight: .medium
        )
        helpButton.symbolConfiguration = symbolConfiguration
        extensionButton.symbolConfiguration = symbolConfiguration
        shortcutDiscoveryButton.symbolConfiguration = symbolConfiguration
        proDismissButton.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: GlobalFontMagnification.scaledSize(8),
            weight: .bold
        )
        proButton.font = GlobalFontMagnification.systemFont(ofSize: 11, weight: .medium)
        updateButton.font = GlobalFontMagnification.systemFont(ofSize: 11, weight: .medium)
        devBuildBannerLabel.font = GlobalFontMagnification.systemFont(
            ofSize: 11,
            weight: .semibold
        )
        proButton.invalidateIntrinsicContentSize()
        updateButton.invalidateIntrinsicContentSize()
        proBadgeView.invalidateIntrinsicContentSize()
        buttonStack.needsLayout = true
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    @objc private func showHelpMenu(_ sender: NSButton) {
        helpMenuController.present(relativeTo: sender)
    }

    @objc private func openExtensionBrowser(_ sender: NSButton) {
        callbacks.onOpenExtensionBrowser(sender)
    }

    @objc private func openPricing(_ sender: NSButton) {
        _ = sender
        callbacks.onOpenPricing()
    }

    @objc private func dismissPro(_ sender: NSButton) {
        _ = sender
        callbacks.onDismissPro()
    }

    @objc private func showUpdate(_ sender: NSButton) {
        updatePopoverController.handleTap(relativeTo: sender)
    }

    @objc private func showShortcutDiscovery(_ sender: NSButton) {
        shortcutMenuController.present(relativeTo: sender)
    }
}

/// Native hover shell for the Pro badge. The pricing button stays the primary
/// action while an adjacent dismiss affordance is revealed under the pointer,
/// matching the existing sidebar badge behavior without hosting SwiftUI.
@MainActor
private final class SidebarAppKitProBadgeView: NSView {
    private let stack: NSStackView
    private let dismissButton: NSButton
    private var trackingArea: NSTrackingArea?

    init(primaryButton: NSButton, dismissButton: NSButton) {
        self.dismissButton = dismissButton
        stack = NSStackView(views: [primaryButton, dismissButton])
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = 0
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        dismissButton.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        stack.fittingSize
    }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let next = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(next)
        trackingArea = next
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        setDismissVisible(true)
        ProUpgradePresenter.prefetch()
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        setDismissVisible(false)
        super.mouseExited(with: event)
    }

    func resetHover() {
        setDismissVisible(false)
    }

    private func setDismissVisible(_ visible: Bool) {
        guard dismissButton.isHidden == visible else { return }
        dismissButton.isHidden = !visible
        invalidateIntrinsicContentSize()
        superview?.needsLayout = true
    }
}

/// Native equivalent of `UpdatePill.handleTap` and its update popover.
///
/// The state machine and phase callbacks remain owned by `UpdateStateModel` and
/// `UpdateController`; this controller only maps the current state to retained
/// AppKit controls and invokes the same check/install/cancel/retry callbacks.
@MainActor
private final class SidebarAppKitUpdatePopoverController: NSObject, NSPopoverDelegate {
    struct Actions {
        let checkForUpdatesInCustomUI: () -> Void
        let attemptUpdate: () -> Void
        let updateLogPath: () -> String
    }

    private enum Metrics {
        static let width: CGFloat = 300
        static let inset: CGFloat = 16
        static let maximumHeight: CGFloat = 480
    }

    private let model: UpdateStateModel
    private let actions: Actions
    private let popover = NSPopover()
    private let contentController = NSViewController()
    private var allowsPresentation = false
    private var fontMagnificationObserver: GlobalFontMagnificationChangeObserver?

    init(model: UpdateStateModel, actions: Actions) {
        self.model = model
        self.actions = actions
        super.init()
        popover.behavior = .semitransient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = contentController
        fontMagnificationObserver = GlobalFontMagnificationChangeObserver { [weak self] in
            guard let self, popover.isShown else { return }
            installCurrentContent()
        }
    }

    /// Matches `UpdatePill.handleTap`: passive detected updates open details
    /// and hydrate missing appcast metadata; a no-update result acknowledges
    /// immediately; every other phase toggles the state-specific popover.
    func handleTap(relativeTo anchorView: NSView) {
        guard allowsPresentation else { return }

        if model.showsDetectedBackgroundUpdate {
            if popover.isShown {
                dismiss()
                return
            }
            present(relativeTo: anchorView)
            if !model.hasCachedDetectedUpdateDetails {
                actions.checkForUpdatesInCustomUI()
            }
            return
        }

        if case .notFound(let notFound) = model.state {
            model.setState(.idle)
            notFound.acknowledgement()
            dismiss()
            return
        }

        if popover.isShown {
            dismiss()
        } else {
            present(relativeTo: anchorView)
        }
    }

    func refresh(allowsPresentation: Bool) {
        self.allowsPresentation = allowsPresentation
        guard allowsPresentation else {
            dismiss()
            return
        }
        if popover.isShown {
            installCurrentContent()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        _ = notification
    }

    private func present(relativeTo anchorView: NSView) {
        installCurrentContent()
        guard !popover.isShown else { return }
        popover.show(
            relativeTo: anchorView.bounds,
            of: anchorView,
            preferredEdge: .maxY
        )
    }

    private func dismiss() {
        if popover.isShown {
            popover.performClose(nil)
        }
    }

    private func installCurrentContent() {
        let content = makeCurrentContent()
        let size = content.frame.size
        contentController.view = content
        contentController.preferredContentSize = size
        popover.contentSize = size
    }

    private func makeCurrentContent() -> NSView {
        let stack: NSStackView
        switch model.effectiveState {
        case .idle:
            stack = makeDetectedUpdateContent()
        case .permissionRequest(let request):
            stack = makePermissionContent(request)
        case .checking(let checking):
            stack = makeCheckingContent(checking)
        case .updateAvailable(let update):
            stack = makeAvailableContent(update)
        case .downloading(let download):
            stack = makeDownloadingContent(download)
        case .extracting(let extracting):
            stack = makeExtractingContent(extracting)
        case .installing(let installing):
            stack = makeInstallingContent(installing)
        case .notFound(let notFound):
            stack = makeNotFoundContent(notFound)
        case .error(let error):
            stack = makeErrorContent(error)
        }
        return wrap(stack)
    }

    private func makeDetectedUpdateContent() -> NSStackView {
        let stack = makeVerticalStack(spacing: 12)
        stack.addArrangedSubview(titleLabel(String(
            localized: "update.popover.updateAvailable",
            defaultValue: "Update Available"
        )))

        if let item = model.detectedUpdateItem {
            stack.addArrangedSubview(metadataView(for: item))
            stack.addArrangedSubview(buttonRow(
                leading: [actionButton(
                    String(localized: "common.later", defaultValue: "Later"),
                    cancel: true
                ) { [weak self] in self?.dismiss() }],
                trailing: [actionButton(
                    String(
                        localized: "common.installAndRelaunch",
                        defaultValue: "Install and Relaunch"
                    ),
                    primary: true
                ) { [weak self] in
                    self?.actions.attemptUpdate()
                    self?.dismiss()
                }]
            ))
            if let notes = UpdateState.ReleaseNotes(
                displayVersionString: item.displayVersionString
            ) {
                stack.addArrangedSubview(linkButton(notes.label, url: notes.url))
            }
        } else {
            if let version = model.detectedUpdateVersion {
                stack.addArrangedSubview(metadataRow(
                    label: String(
                        localized: "update.popover.version",
                        defaultValue: "Version:"
                    ),
                    value: version
                ))
            }
            stack.addArrangedSubview(statusRow(
                String(
                    localized: "update.popover.checking",
                    defaultValue: "Checking for updates…"
                ),
                progress: nil,
                indeterminate: true
            ))
        }
        return stack
    }

    private func makePermissionContent(
        _ request: UpdateState.PermissionRequest
    ) -> NSStackView {
        let stack = makeVerticalStack(spacing: 12)
        stack.addArrangedSubview(titleLabel(String(
            localized: "update.popover.enableAutoUpdates",
            defaultValue: "Enable automatic updates?"
        )))
        stack.addArrangedSubview(detailLabel(String(
            localized: "update.popover.autoUpdatesDescription",
            defaultValue: "cmux can automatically check for updates in the background."
        )))
        stack.addArrangedSubview(buttonRow(
            leading: [actionButton(
                String(localized: "common.notNow", defaultValue: "Not Now"),
                cancel: true
            ) { [weak self] in
                request.reply(SUUpdatePermissionResponse(
                    automaticUpdateChecks: false,
                    sendSystemProfile: false
                ))
                self?.dismiss()
            }],
            trailing: [actionButton(
                String(localized: "common.allow", defaultValue: "Allow"),
                primary: true
            ) { [weak self] in
                request.reply(SUUpdatePermissionResponse(
                    automaticUpdateChecks: true,
                    sendSystemProfile: false
                ))
                self?.dismiss()
            }]
        ))
        return stack
    }

    private func makeCheckingContent(_ checking: UpdateState.Checking) -> NSStackView {
        let stack = makeVerticalStack(spacing: 12)
        stack.addArrangedSubview(statusRow(
            String(
                localized: "update.popover.checking",
                defaultValue: "Checking for updates…"
            ),
            progress: nil,
            indeterminate: true
        ))
        stack.addArrangedSubview(buttonRow(
            leading: [],
            trailing: [actionButton(
                String(localized: "common.cancel", defaultValue: "Cancel"),
                cancel: true
            ) { [weak self] in
                checking.cancel()
                self?.dismiss()
            }]
        ))
        return stack
    }

    private func makeAvailableContent(
        _ update: UpdateState.UpdateAvailable
    ) -> NSStackView {
        let stack = makeVerticalStack(spacing: 12)
        stack.addArrangedSubview(titleLabel(String(
            localized: "update.popover.updateAvailable",
            defaultValue: "Update Available"
        )))
        stack.addArrangedSubview(metadataView(for: update.appcastItem))
        stack.addArrangedSubview(buttonRow(
            leading: [
                actionButton(String(localized: "common.skip", defaultValue: "Skip")) {
                    [weak self] in
                    update.reply(.skip)
                    self?.dismiss()
                },
                actionButton(
                    String(localized: "common.later", defaultValue: "Later"),
                    cancel: true
                ) { [weak self] in
                    update.reply(.dismiss)
                    self?.dismiss()
                },
            ],
            trailing: [actionButton(
                String(
                    localized: "common.installAndRelaunch",
                    defaultValue: "Install and Relaunch"
                ),
                primary: true
            ) { [weak self] in
                self?.actions.attemptUpdate()
                self?.dismiss()
            }]
        ))
        if let notes = update.releaseNotes {
            stack.addArrangedSubview(linkButton(notes.label, url: notes.url))
        }
        return stack
    }

    private func makeDownloadingContent(
        _ download: UpdateState.Downloading
    ) -> NSStackView {
        let stack = makeVerticalStack(spacing: 12)
        stack.addArrangedSubview(titleLabel(String(
            localized: "update.popover.downloadingUpdate",
            defaultValue: "Downloading Update"
        )))
        let progress = download.expectedLength.flatMap { expected -> Double? in
            guard expected > 0 else { return nil }
            return min(1, max(0, Double(download.progress) / Double(expected)))
        }
        stack.addArrangedSubview(progressView(value: progress))
        stack.addArrangedSubview(buttonRow(
            leading: [],
            trailing: [actionButton(
                String(localized: "common.cancel", defaultValue: "Cancel"),
                cancel: true
            ) { [weak self] in
                download.cancel()
                self?.dismiss()
            }]
        ))
        return stack
    }

    private func makeExtractingContent(
        _ extracting: UpdateState.Extracting
    ) -> NSStackView {
        let stack = makeVerticalStack(spacing: 12)
        stack.addArrangedSubview(titleLabel(String(
            localized: "update.popover.preparingUpdate",
            defaultValue: "Preparing Update"
        )))
        stack.addArrangedSubview(progressView(
            value: min(1, max(0, extracting.progress))
        ))
        return stack
    }

    private func makeInstallingContent(
        _ installing: UpdateState.Installing
    ) -> NSStackView {
        let stack = makeVerticalStack(spacing: 12)
        stack.addArrangedSubview(titleLabel(String(
            localized: "update.popover.restartRequired",
            defaultValue: "Restart Required"
        )))
        stack.addArrangedSubview(detailLabel(String(
            localized: "update.popover.restartRequired.message",
            defaultValue: "The update is ready. Please restart the application to complete the installation."
        )))
        stack.addArrangedSubview(buttonRow(
            leading: [actionButton(
                String(localized: "common.restartLater", defaultValue: "Restart Later"),
                cancel: true
            ) { [weak self] in
                installing.dismiss()
                self?.dismiss()
            }],
            trailing: [actionButton(
                String(localized: "common.restartNow", defaultValue: "Restart Now"),
                primary: true
            ) { [weak self] in
                installing.retryTerminatingApplication()
                self?.dismiss()
            }]
        ))
        return stack
    }

    private func makeNotFoundContent(
        _ notFound: UpdateState.NotFound
    ) -> NSStackView {
        let stack = makeVerticalStack(spacing: 12)
        stack.addArrangedSubview(titleLabel(String(
            localized: "update.popover.noUpdatesFound",
            defaultValue: "No Updates Found"
        )))
        stack.addArrangedSubview(detailLabel(String(
            localized: "update.popover.noUpdatesFound.message",
            defaultValue: "You're already running the latest version."
        )))
        stack.addArrangedSubview(buttonRow(
            leading: [],
            trailing: [actionButton(
                String(localized: "common.ok", defaultValue: "OK"),
                primary: true
            ) { [weak self] in
                notFound.acknowledgement()
                self?.dismiss()
            }]
        ))
        return stack
    }

    private func makeErrorContent(_ error: UpdateState.Error) -> NSStackView {
        let stack = makeVerticalStack(spacing: 12)
        stack.addArrangedSubview(titleLabel(
            UpdateStateModel.userFacingErrorTitle(for: error.error)
        ))
        stack.addArrangedSubview(detailLabel(
            UpdateStateModel.userFacingErrorMessage(for: error.error)
        ))

        if let downloadURL = UpdateManualDownloadRecovery().url(
            for: error.error,
            feedURLString: error.feedURLString
        ) {
            stack.addArrangedSubview(actionButton(
                String(
                    localized: "update.error.downloadLatest.button",
                    defaultValue: "Download Latest Version"
                ),
                primary: true
            ) {
                NSWorkspace.shared.open(downloadURL)
            })
        }

        let details = UpdateErrorDetailsFormatter().details(
            for: error.error,
            technicalDetails: error.technicalDetails,
            feedURLString: error.feedURLString,
            logPath: actions.updateLogPath()
        )
        stack.addArrangedSubview(detailTextView(details))
        stack.addArrangedSubview(buttonRow(
            leading: [
                actionButton(
                    String(localized: "common.copyDetails", defaultValue: "Copy Details")
                ) {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(details, forType: .string)
                },
                actionButton(
                    String(localized: "common.ok", defaultValue: "OK"),
                    cancel: true
                ) { [weak self] in
                    error.dismiss()
                    self?.dismiss()
                },
            ],
            trailing: [actionButton(
                String(localized: "common.retry", defaultValue: "Retry"),
                primary: true
            ) { [weak self] in
                error.retry()
                self?.dismiss()
            }]
        ))
        return stack
    }

    private func makeVerticalStack(spacing: CGFloat) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = spacing
        return stack
    }

    private func titleLabel(_ text: String) -> NSTextField {
        let label = wrappingLabel(text, size: 13, weight: .semibold)
        label.textColor = .labelColor
        return label
    }

    private func detailLabel(_ text: String) -> NSTextField {
        let label = wrappingLabel(text, size: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func wrappingLabel(
        _ text: String,
        size: CGFloat,
        weight: NSFont.Weight
    ) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = GlobalFontMagnification.systemFont(ofSize: size, weight: weight)
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.preferredMaxLayoutWidth = Metrics.width - 2 * Metrics.inset
        label.isSelectable = true
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }

    private func metadataView(for item: SUAppcastItem) -> NSView {
        let stack = makeVerticalStack(spacing: 4)
        stack.addArrangedSubview(metadataRow(
            label: String(localized: "update.popover.version", defaultValue: "Version:"),
            value: item.displayVersionString
        ))
        if item.contentLength > 0 {
            stack.addArrangedSubview(metadataRow(
                label: String(localized: "update.popover.size", defaultValue: "Size:"),
                value: ByteCountFormatter.string(
                    fromByteCount: Int64(item.contentLength),
                    countStyle: .file
                )
            ))
        }
        if let date = item.date {
            stack.addArrangedSubview(metadataRow(
                label: String(localized: "update.popover.released", defaultValue: "Released:"),
                value: date.formatted(date: .abbreviated, time: .omitted)
            ))
        }
        return stack
    }

    private func metadataRow(label: String, value: String) -> NSView {
        let labelField = NSTextField(labelWithString: label)
        labelField.font = GlobalFontMagnification.systemFont(ofSize: 11)
        labelField.textColor = .secondaryLabelColor
        labelField.alignment = .right
        labelField.setContentHuggingPriority(.required, for: .horizontal)
        labelField.widthAnchor.constraint(equalToConstant: 60).isActive = true

        let valueField = NSTextField(labelWithString: value)
        valueField.font = GlobalFontMagnification.systemFont(ofSize: 11)
        valueField.lineBreakMode = .byTruncatingTail
        valueField.isSelectable = true
        valueField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [labelField, valueField])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 6
        return row
    }

    private func statusRow(
        _ text: String,
        progress: Double?,
        indeterminate: Bool
    ) -> NSView {
        let indicator = NSProgressIndicator()
        indicator.controlSize = .small
        if indeterminate {
            indicator.style = .spinning
            indicator.isIndeterminate = true
            indicator.startAnimation(nil)
            indicator.widthAnchor.constraint(equalToConstant: 16).isActive = true
            indicator.heightAnchor.constraint(equalToConstant: 16).isActive = true
        } else {
            indicator.style = .bar
            indicator.isIndeterminate = false
            indicator.minValue = 0
            indicator.maxValue = 1
            indicator.doubleValue = progress ?? 0
            indicator.widthAnchor.constraint(equalToConstant: 100).isActive = true
        }
        let label = NSTextField(labelWithString: text)
        label.font = GlobalFontMagnification.systemFont(ofSize: 13)
        let row = NSStackView(views: [indicator, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 10
        return row
    }

    private func progressView(value: Double?) -> NSView {
        guard let value else {
            return statusRow(
                String(localized: "update.downloading.status", defaultValue: "Downloading…"),
                progress: nil,
                indeterminate: true
            )
        }
        let clamped = min(1, max(0, value))
        let indicator = NSProgressIndicator()
        indicator.style = .bar
        indicator.isIndeterminate = false
        indicator.minValue = 0
        indicator.maxValue = 1
        indicator.doubleValue = clamped

        let percentage = NSTextField(labelWithString: String(format: "%.0f%%", clamped * 100))
        percentage.font = GlobalFontMagnification.systemFont(ofSize: 11)
        percentage.textColor = .secondaryLabelColor

        let stack = makeVerticalStack(spacing: 6)
        stack.addArrangedSubview(indicator)
        stack.addArrangedSubview(percentage)
        indicator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func detailTextView(_ text: String) -> NSView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            assertionFailure("NSTextView.scrollableTextView() must contain an NSTextView")
            return scrollView
        }
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = GlobalFontMagnification.monospacedSystemFont(
            ofSize: 10,
            weight: .regular
        )
        textView.textColor = .secondaryLabelColor
        textView.string = text
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.textContainer?.widthTracksTextView = true

        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.heightAnchor.constraint(equalToConstant: 150).isActive = true
        return scrollView
    }

    private func buttonRow(
        leading: [NSButton],
        trailing: [NSButton]
    ) -> NSView {
        let spacer = NSView(frame: .zero)
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: leading + [spacer] + trailing)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 8
        return row
    }

    private func actionButton(
        _ title: String,
        primary: Bool = false,
        cancel: Bool = false,
        action: @escaping @MainActor () -> Void
    ) -> NSButton {
        let button = SidebarAppKitActionButton(title: title, action: action)
        button.controlSize = .small
        button.bezelStyle = primary ? .texturedRounded : .rounded
        if primary {
            button.keyEquivalent = "\r"
        } else if cancel {
            button.keyEquivalent = "\u{1b}"
        }
        return button
    }

    private func linkButton(_ title: String, url: URL) -> NSButton {
        let button = actionButton(title) {
            NSWorkspace.shared.open(url)
        }
        button.image = NSImage(
            systemSymbolName: "arrow.up.right",
            accessibilityDescription: nil
        )
        button.imagePosition = .imageTrailing
        button.alignment = .left
        return button
    }

    private func wrap(_ contentStack: NSStackView) -> NSView {
        let contentWidth = Metrics.width - 2 * Metrics.inset
        contentStack.frame = NSRect(x: 0, y: 0, width: contentWidth, height: 1)
        contentStack.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        for arrangedSubview in contentStack.arrangedSubviews {
            arrangedSubview.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }
        contentStack.layoutSubtreeIfNeeded()
        let contentHeight = ceil(contentStack.fittingSize.height)
        let height = min(
            Metrics.maximumHeight,
            max(1, contentHeight + 2 * Metrics.inset)
        )
        let root = NSView(frame: NSRect(
            x: 0,
            y: 0,
            width: Metrics.width,
            height: height
        ))
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Metrics.inset),
            contentStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Metrics.inset),
            contentStack.topAnchor.constraint(equalTo: root.topAnchor, constant: Metrics.inset),
            contentStack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -Metrics.inset),
        ])
        root.layoutSubtreeIfNeeded()
        return root
    }
}

/// Target-action bridge that owns a main-actor closure without using Objective-C
/// associated storage or rebuilding the footer's controller hierarchy.
@MainActor
private final class SidebarAppKitActionButton: NSButton {
    private let handler: @MainActor () -> Void

    init(title: String, action: @escaping @MainActor () -> Void) {
        handler = action
        super.init(frame: .zero)
        self.title = title
        target = self
        self.action = #selector(performAction(_:))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func performAction(_ sender: NSButton) {
        _ = sender
        handler()
    }
}
