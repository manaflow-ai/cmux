import AppKit
import Bonsplit
import CmuxFoundation
import CmuxSettings
import CmuxTerminal
import CmuxTestSupport
import Combine
import Foundation

@MainActor
private final class TerminalPanelRootView: NSView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}

/// Native AppKit owner for a terminal pane. The Ghostty surface stays mounted
/// in a stable native anchor while hibernation and composer state change.
@MainActor
final class TerminalPanelNativeViewController: NSViewController, PanelContentControllerUpdating {
    private var configuration: PanelContentConfiguration
    private let panel: TerminalPanel
    private let contentContainer = NSView()
    private var terminalView: GhosttyTerminalView?
    private var textBoxController: TerminalTextBoxInputHostingController?
    private var placeholderController: AgentHibernationPlaceholderNativeViewController?
    private var contentConstraints: [NSLayoutConstraint] = []
    private var panelCancellable: AnyCancellable?
    private var panelRefreshTask: Task<Void, Never>?
    private var defaultsObservationTask: Task<Void, Never>?
    private var configObservationTask: Task<Void, Never>?
    private var autoResumeTask: Task<Void, Never>?
    private var autoResumeHibernatedAt: Date?
    private var notificationPaneRingEnabled = NotificationPaneRingSettings.defaultEnabled
    private var textBoxMaxLines = TerminalTextBoxInputSettings.defaultMaxLines
    private var sessionContentWidthPresentation = SessionContentWidthPresentation.disabled
    private var terminalFontSize = GhosttyConfig.load(
        globalFontMagnificationPercent: GlobalFontMagnification.storedPercent
    ).fontSize
    private var isTornDown = false

    init(configuration: PanelContentConfiguration) {
        guard let panel = configuration.panel as? TerminalPanel else {
            preconditionFailure("TerminalPanelNativeViewController requires TerminalPanel")
        }
        self.configuration = configuration
        self.panel = panel
        super.init(nibName: nil, bundle: nil)
        refreshStoredSettings()
        startObserving()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = TerminalPanelRootView(frame: .zero)
        root.wantsLayer = true
        root.onLayout = { [weak self] in
            self?.recordTerminalViewportGeometryForUITest()
        }
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(contentContainer)
        NSLayoutConstraint.activate([
            contentContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: root.topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        render()
    }

    func update(configuration: PanelContentConfiguration) {
        self.configuration = configuration
        if isTornDown {
            isTornDown = false
            startObserving()
        }
        render()
    }

    func teardownPanelContent() {
        guard !isTornDown else { return }
        isTornDown = true
        panelCancellable?.cancel()
        panelCancellable = nil
        panelRefreshTask?.cancel()
        panelRefreshTask = nil
        defaultsObservationTask?.cancel()
        defaultsObservationTask = nil
        configObservationTask?.cancel()
        configObservationTask = nil
        autoResumeTask?.cancel()
        autoResumeTask = nil
        removeLiveContent()
        removePlaceholder()
    }

    private func startObserving() {
        panelCancellable?.cancel()
        panelCancellable = panel.objectWillChange.sink { [weak self] in
            self?.schedulePanelRefresh()
        }

        defaultsObservationTask?.cancel()
        defaultsObservationTask = Task { @MainActor [weak self] in
            let notifications = NotificationCenter.default.notifications(
                named: UserDefaults.didChangeNotification
            )
            for await _ in notifications {
                guard !Task.isCancelled, let self else { return }
                self.refreshStoredSettings()
                self.render()
            }
        }

        configObservationTask?.cancel()
        configObservationTask = Task { @MainActor [weak self] in
            let notifications = NotificationCenter.default.notifications(
                named: .ghosttyConfigDidReload
            )
            for await _ in notifications {
                guard !Task.isCancelled, let self else { return }
                self.terminalFontSize = GhosttyConfig.load(
                    globalFontMagnificationPercent: GlobalFontMagnification.storedPercent
                ).fontSize
                self.render()
            }
        }
    }

    private func schedulePanelRefresh() {
        panelRefreshTask?.cancel()
        panelRefreshTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self, !self.isTornDown else { return }
            self.panelRefreshTask = nil
            self.render()
        }
    }

    private func refreshStoredSettings(defaults: UserDefaults = .standard) {
        if defaults.object(forKey: NotificationPaneRingSettings.enabledKey) == nil {
            notificationPaneRingEnabled = NotificationPaneRingSettings.defaultEnabled
        } else {
            notificationPaneRingEnabled = defaults.bool(
                forKey: NotificationPaneRingSettings.enabledKey
            )
        }
        textBoxMaxLines = TerminalTextBoxInputSettings.resolvedMaxLines(
            defaults.object(forKey: TerminalTextBoxInputSettings.maxLinesKey) as? Int
                ?? TerminalTextBoxInputSettings.defaultMaxLines
        )
        let storedMaximumWidth = (
            defaults.object(forKey: SessionContentWidthSettings.maxWidthKey) as? NSNumber
        )?.doubleValue ?? SessionContentWidthSettings.noMaximumWidth
        let storedAlignment = defaults.string(forKey: SessionContentWidthSettings.alignmentKey)
            ?? SessionContentAlignment.center.rawValue
        sessionContentWidthPresentation = SessionContentWidthPresentation(
            storedMaximumWidth: storedMaximumWidth,
            storedAlignment: storedAlignment
        )
    }

    private func render() {
        guard isViewLoaded, !isTornDown else { return }
        view.layer?.backgroundColor = configuration.appearance.contentBackgroundColor.cgColor

        switch panel.agentHibernationPhase {
        case .live:
            autoResumeHibernatedAt = nil
            autoResumeTask?.cancel()
            autoResumeTask = nil
            removePlaceholder()
            showLiveContent()
        case .terminating:
            autoResumeHibernatedAt = nil
            showSolidBackground()
        case .recovering(let state):
            autoResumeHibernatedAt = nil
            showPlaceholder(state: state, mode: .recovering, onAction: nil)
        case .terminationFailed(let state):
            autoResumeHibernatedAt = nil
            showPlaceholder(
                state: state,
                mode: .failed,
                onAction: { [weak panel] in panel?.retryAgentHibernationTermination() }
            )
        case .hibernated(let state):
            if configuration.isVisibleInUI {
                showSolidBackground()
                scheduleAutoResume(for: state)
            } else {
                autoResumeHibernatedAt = nil
                autoResumeTask?.cancel()
                autoResumeTask = nil
                showPlaceholder(
                    state: state,
                    mode: .hibernated,
                    onAction: configuration.onResumeAgentHibernation
                )
            }
        }
    }

    private func showLiveContent() {
        let terminalView: GhosttyTerminalView
        if let existing = self.terminalView {
            terminalView = existing
        } else {
            terminalView = makeTerminalView()
            terminalView.translatesAutoresizingMaskIntoConstraints = false
            contentContainer.addSubview(terminalView)
            self.terminalView = terminalView
        }
        terminalView.update(
            terminalSurface: panel.surface,
            paneId: configuration.paneID,
            isActive: configuration.isFocused,
            isVisibleInUI: configuration.isVisibleInUI,
            ownershipGeneration: panel.portalHostOwnershipGeneration,
            isCurrentPaneOwner: currentPortalPaneOwner,
            portalZPriority: configuration.portalPriority,
            showsInactiveOverlay: configuration.isSplit && !configuration.isFocused,
            showsUnreadNotificationRing: configuration.hasUnreadNotification
                && notificationPaneRingEnabled,
            inactiveOverlayColor: configuration.appearance.unfocusedOverlayNSColor,
            inactiveOverlayOpacity: configuration.appearance.unfocusedOverlayOpacity,
            searchState: panel.searchState,
            sessionContentWidthPresentation: sessionContentWidthPresentation,
            paneDropZone: configuration.paneDropZone,
            onFocus: { [weak self] _ in
                guard let self else { return }
                self.panel.terminalDidBecomeFocused()
                self.configuration.onFocus()
            },
            onTriggerFlash: configuration.onTriggerFlash
        )

        let textBoxView: NSView?
        if panel.isTextBoxActive {
            textBoxView = installOrUpdateTextBoxController().view
        } else {
            removeTextBoxController()
            textBoxView = nil
        }
        updateLiveConstraints(terminalView: terminalView, textBoxView: textBoxView)
    }

    private func makeTerminalView() -> GhosttyTerminalView {
        GhosttyTerminalView(
            terminalSurface: panel.surface,
            paneId: configuration.paneID,
            isActive: configuration.isFocused,
            isVisibleInUI: configuration.isVisibleInUI,
            ownershipGeneration: panel.portalHostOwnershipGeneration,
            isCurrentPaneOwner: currentPortalPaneOwner,
            portalZPriority: configuration.portalPriority,
            showsInactiveOverlay: configuration.isSplit && !configuration.isFocused,
            showsUnreadNotificationRing: configuration.hasUnreadNotification
                && notificationPaneRingEnabled,
            inactiveOverlayColor: configuration.appearance.unfocusedOverlayNSColor,
            inactiveOverlayOpacity: configuration.appearance.unfocusedOverlayOpacity,
            searchState: panel.searchState,
            sessionContentWidthPresentation: sessionContentWidthPresentation,
            paneDropZone: configuration.paneDropZone,
            onFocus: { [weak self] _ in
                guard let self else { return }
                self.panel.terminalDidBecomeFocused()
                self.configuration.onFocus()
            },
            onTriggerFlash: configuration.onTriggerFlash
        )
    }

    private func installOrUpdateTextBoxController() -> TerminalTextBoxInputHostingController {
        let font = NSFont.monospacedSystemFont(ofSize: terminalFontSize, weight: .regular)
        if let textBoxController {
            textBoxController.update(
                terminalBackgroundColor: configuration.appearance.backgroundColor,
                terminalForegroundColor: configuration.appearance.foregroundColor,
                terminalFont: font,
                maxLines: textBoxMaxLines,
                terminalAgentContext: configuration.terminalAgentContext,
                sessionContentWidthPresentation: sessionContentWidthPresentation,
                onFocus: configuration.onFocus
            )
            return textBoxController
        }

        let controller = TerminalTextBoxInputHostingController(
            panel: panel,
            terminalBackgroundColor: configuration.appearance.backgroundColor,
            terminalForegroundColor: configuration.appearance.foregroundColor,
            terminalFont: font,
            maxLines: textBoxMaxLines,
            terminalAgentContext: configuration.terminalAgentContext,
            sessionContentWidthPresentation: sessionContentWidthPresentation,
            onFocus: configuration.onFocus
        )
        addChild(controller)
        let textBoxView = controller.view
        textBoxView.translatesAutoresizingMaskIntoConstraints = false
        textBoxView.setContentHuggingPriority(.required, for: .vertical)
        textBoxView.setContentCompressionResistancePriority(.required, for: .vertical)
        contentContainer.addSubview(textBoxView)
        textBoxController = controller
        return controller
    }

    private func updateLiveConstraints(terminalView: NSView, textBoxView: NSView?) {
        NSLayoutConstraint.deactivate(contentConstraints)
        var constraints = [
            terminalView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            terminalView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
        ]
        if let textBoxView {
            constraints.append(contentsOf: [
                terminalView.bottomAnchor.constraint(equalTo: textBoxView.topAnchor),
                textBoxView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
                textBoxView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
                textBoxView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            ])
        } else {
            constraints.append(
                terminalView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
            )
        }
        contentConstraints = constraints
        NSLayoutConstraint.activate(constraints)
    }

    private func removeTextBoxController() {
        guard let textBoxController else { return }
        NSLayoutConstraint.deactivate(contentConstraints)
        contentConstraints = []
        textBoxController.view.removeFromSuperview()
        textBoxController.removeFromParent()
        self.textBoxController = nil
    }

    private func removeLiveContent() {
        NSLayoutConstraint.deactivate(contentConstraints)
        contentConstraints = []
        removeTextBoxController()
        terminalView?.teardown()
        terminalView?.removeFromSuperview()
        terminalView = nil
    }

    private func showSolidBackground() {
        autoResumeTask?.cancel()
        autoResumeTask = nil
        removeLiveContent()
        removePlaceholder()
    }

    private func showPlaceholder(
        state: AgentHibernationPanelState,
        mode: AgentHibernationPlaceholderMode,
        onAction: (() -> Void)?
    ) {
        autoResumeTask?.cancel()
        autoResumeTask = nil
        removeLiveContent()
        if let placeholderController {
            placeholderController.update(
                state: state,
                appearance: configuration.appearance,
                mode: mode,
                onAction: onAction
            )
            return
        }

        let controller = AgentHibernationPlaceholderNativeViewController(
            state: state,
            appearance: configuration.appearance,
            mode: mode,
            onAction: onAction
        )
        addChild(controller)
        let placeholder = controller.view
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            placeholder.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            placeholder.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            placeholder.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
        placeholderController = controller
    }

    private func removePlaceholder() {
        guard let placeholderController else { return }
        placeholderController.view.removeFromSuperview()
        placeholderController.removeFromParent()
        self.placeholderController = nil
    }

    private func scheduleAutoResume(for state: AgentHibernationPanelState) {
        guard autoResumeHibernatedAt != state.hibernatedAt else { return }
        autoResumeHibernatedAt = state.hibernatedAt
        autoResumeTask?.cancel()
        autoResumeTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled,
                  let self,
                  self.configuration.isVisibleInUI,
                  case .hibernated(let currentState) = self.panel.agentHibernationPhase,
                  currentState.hibernatedAt == state.hibernatedAt else { return }
            self.configuration.onAutoResumeAgentHibernation()
        }
    }

    private func currentPortalPaneOwner() -> Bool {
        if let resolver = configuration.terminalPaneOwnershipResolver {
            return resolver()
        }
        guard let app = AppDelegate.shared,
              let manager = app.tabManagerFor(tabId: panel.workspaceId),
              let workspace = manager.tabs.first(where: { $0.id == panel.workspaceId }),
              let livePanel = workspace.panels[panel.id],
              livePanel === panel,
              let currentPane = workspace.paneId(forPanelId: panel.id),
              currentPane.id == configuration.paneID.id,
              let tabID = workspace.surfaceIdFromPanelId(panel.id) else {
            return false
        }
        return workspace.bonsplitController.selectedTab(inPane: currentPane)?.id == tabID
    }

    private func recordTerminalViewportGeometryForUITest() {
#if DEBUG
        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_TERMINAL_VIEWPORT_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              let terminalView else { return }

        let hostedView = panel.hostedView
        let hostedFrame = hostedView.frame
        let hostedBounds = hostedView.bounds
        let hostedSuperviewBounds = hostedView.superview?.bounds ?? .zero
        let windowContentBounds = hostedView.window?.contentView?.bounds ?? .zero
        let hostedFrameInContent: NSRect
        if let contentView = hostedView.window?.contentView {
            hostedFrameInContent = contentView.convert(
                hostedView.convert(hostedView.bounds, to: nil),
                from: nil
            )
        } else {
            hostedFrameInContent = .zero
        }

        _ = UITestCaptureSink().mutateJSONObjectIfConfigured(
            envKey: "CMUX_UI_TEST_TERMINAL_VIEWPORT_PATH"
        ) { payload in
            payload["terminalViewportPanelId"] = panel.id.uuidString
            payload["terminalViewportPanelWidth"] = terminalViewportFormat(terminalView.bounds.width)
            payload["terminalViewportPanelHeight"] = terminalViewportFormat(terminalView.bounds.height)
            payload["terminalViewportHostedFrameMinX"] = terminalViewportFormat(hostedFrame.minX)
            payload["terminalViewportHostedFrameMinY"] = terminalViewportFormat(hostedFrame.minY)
            payload["terminalViewportHostedFrameMaxX"] = terminalViewportFormat(hostedFrame.maxX)
            payload["terminalViewportHostedFrameMaxY"] = terminalViewportFormat(hostedFrame.maxY)
            payload["terminalViewportHostedFrameWidth"] = terminalViewportFormat(hostedFrame.width)
            payload["terminalViewportHostedFrameHeight"] = terminalViewportFormat(hostedFrame.height)
            payload["terminalViewportHostedBoundsWidth"] = terminalViewportFormat(hostedBounds.width)
            payload["terminalViewportHostedBoundsHeight"] = terminalViewportFormat(hostedBounds.height)
            payload["terminalViewportHostedSuperviewWidth"] = terminalViewportFormat(hostedSuperviewBounds.width)
            payload["terminalViewportHostedSuperviewHeight"] = terminalViewportFormat(hostedSuperviewBounds.height)
            payload["terminalViewportWindowContentWidth"] = terminalViewportFormat(windowContentBounds.width)
            payload["terminalViewportWindowContentHeight"] = terminalViewportFormat(windowContentBounds.height)
            payload["terminalViewportHostedContentMinX"] = terminalViewportFormat(hostedFrameInContent.minX)
            payload["terminalViewportHostedContentMinY"] = terminalViewportFormat(hostedFrameInContent.minY)
            payload["terminalViewportHostedContentMaxX"] = terminalViewportFormat(hostedFrameInContent.maxX)
            payload["terminalViewportHostedContentMaxY"] = terminalViewportFormat(hostedFrameInContent.maxY)
        }
#endif
    }
}

@MainActor
private final class AgentHibernationPlaceholderNativeViewController: NSViewController {
    private let stack = NSStackView()
    private var state: AgentHibernationPanelState
    private var appearance: PanelAppearance
    private var mode: AgentHibernationPlaceholderMode
    private var onAction: (() -> Void)?

    init(
        state: AgentHibernationPanelState,
        appearance: PanelAppearance,
        mode: AgentHibernationPlaceholderMode,
        onAction: (() -> Void)?
    ) {
        self.state = state
        self.appearance = appearance
        self.mode = mode
        self.onAction = onAction
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),
        ])
        view = root
        rebuild()
    }

    func update(
        state: AgentHibernationPanelState,
        appearance: PanelAppearance,
        mode: AgentHibernationPlaceholderMode,
        onAction: (() -> Void)?
    ) {
        self.state = state
        self.appearance = appearance
        self.mode = mode
        self.onAction = onAction
        if isViewLoaded { rebuild() }
    }

    private func rebuild() {
        view.layer?.backgroundColor = appearance.contentBackgroundColor.cgColor
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        switch mode {
        case .recovering:
            let progress = NSProgressIndicator()
            progress.style = .spinning
            progress.controlSize = .small
            progress.startAnimation(nil)
            progress.setAccessibilityIdentifier("AgentHibernationTerminationRecoveryProgress")
            stack.addArrangedSubview(progress)
        case .hibernated:
            stack.addArrangedSubview(symbolView(name: "pause.circle"))
        case .failed:
            stack.addArrangedSubview(symbolView(name: "exclamationmark.triangle"))
        }
        stack.setCustomSpacing(14, after: stack.arrangedSubviews.last!)

        let title = wrappingLabel(titleText, font: GlobalFontMagnification.systemFont(
            ofSize: 13,
            weight: .semibold
        ))
        stack.addArrangedSubview(title)

        let agent = wrappingLabel(
            state.agentDisplayName,
            font: GlobalFontMagnification.systemFont(ofSize: 11, weight: .regular)
        )
        agent.textColor = .secondaryLabelColor
        stack.addArrangedSubview(agent)

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let lastActivity = formatter.localizedString(for: state.lastActivityAt, relativeTo: Date())
        let activity = wrappingLabel(
            String.localizedStringWithFormat(
                String(
                    localized: "terminal.agentHibernation.lastActivity",
                    defaultValue: "Last activity %@"
                ),
                lastActivity
            ),
            font: GlobalFontMagnification.systemFont(ofSize: 10, weight: .regular)
        )
        activity.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(activity)

        if let actionTitle, onAction != nil {
            stack.setCustomSpacing(14, after: activity)
            let button = NSButton(title: actionTitle, target: self, action: #selector(performAction))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.keyEquivalent = ""
            button.setAccessibilityIdentifier(
                mode == .failed
                    ? "AgentHibernationTerminationRetryButton"
                    : "AgentHibernationResumeButton"
            )
            stack.addArrangedSubview(button)
        }
    }

    private func wrappingLabel(_ text: String, font: NSFont) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.alignment = .center
        label.font = font
        label.maximumNumberOfLines = 2
        return label
    }

    private func symbolView(name: String) -> NSImageView {
        let image = NSImage(
            systemSymbolName: name,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 34, weight: .regular)) ?? NSImage()
        let view = NSImageView(image: image)
        view.contentTintColor = .secondaryLabelColor
        return view
    }

    private var titleText: String {
        switch mode {
        case .hibernated:
            String(localized: "terminal.agentHibernation.title", defaultValue: "Agent hibernated")
        case .recovering:
            String(
                localized: "terminal.agentHibernation.finishing",
                defaultValue: "Finishing agent shutdown"
            )
        case .failed:
            String(
                localized: "terminal.agentHibernation.failed",
                defaultValue: "Agent shutdown needs attention"
            )
        }
    }

    private var actionTitle: String? {
        switch mode {
        case .hibernated:
            String(localized: "terminal.agentHibernation.resume", defaultValue: "Resume")
        case .recovering:
            nil
        case .failed:
            String(
                localized: "terminal.agentHibernation.retry",
                defaultValue: "Retry shutdown"
            )
        }
    }

    @objc private func performAction() {
        onAction?()
    }
}

extension TerminalPanel {
    static func effectiveTerminalAgentContext(
        _ terminalAgentContext: String,
        pendingLaunchCommand: String?
    ) -> String {
        var context = terminalAgentContext
        guard let command = pendingLaunchCommand?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty else { return context }
        let marker = "textBoxPendingLaunchCommand:\(command)"
        let existingLines = context
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard !existingLines.contains(marker) else { return context }
        if context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            context = marker
        } else {
            context += "\n\(marker)"
        }
        return context
    }
}

#if DEBUG
private func terminalViewportFormat(_ value: CGFloat) -> String {
    String(format: "%.3f", Double(value))
}
#endif

/// Shared appearance settings for panels.
struct PanelAppearance {
    let backgroundColor: NSColor
    let foregroundColor: NSColor
    let dividerColor: NSColor
    let unfocusedOverlayNSColor: NSColor
    let unfocusedOverlayOpacity: Double
    let usesClearContentBackground: Bool

    init(
        backgroundColor: NSColor,
        foregroundColor: NSColor,
        dividerColor: NSColor,
        unfocusedOverlayNSColor: NSColor,
        unfocusedOverlayOpacity: Double,
        usesClearContentBackground: Bool
    ) {
        self.backgroundColor = backgroundColor
        self.foregroundColor = foregroundColor
        self.dividerColor = dividerColor
        self.unfocusedOverlayNSColor = unfocusedOverlayNSColor
        self.unfocusedOverlayOpacity = unfocusedOverlayOpacity
        self.usesClearContentBackground = usesClearContentBackground
    }

    var contentBackgroundColor: NSColor {
        usesClearContentBackground ? .clear : backgroundColor
    }

    var drawsContentBackground: Bool {
        !usesClearContentBackground
    }

    static func fromConfig(_ config: GhosttyConfig) -> PanelAppearance {
        fromConfig(
            config,
            usesTransparentWindow: WindowBackgroundComposition.policy
                .shouldUseTransparentBackgroundWindow(glassEffectAvailable: false)
        )
    }

    static func fromConfig(_ config: GhosttyConfig, usesTransparentWindow: Bool) -> PanelAppearance {
        let backgroundColor = GhosttyBackgroundTheme.color(
            backgroundColor: config.backgroundColor,
            opacity: config.backgroundOpacity
        )
        return PanelAppearance(
            backgroundColor: backgroundColor,
            foregroundColor: cmuxReadableForegroundNSColor(
                preferred: config.foregroundColor,
                on: backgroundColor
            ),
            dividerColor: config.resolvedSplitDividerColor,
            unfocusedOverlayNSColor: config.unfocusedSplitOverlayFill,
            unfocusedOverlayOpacity: config.unfocusedSplitOverlayOpacity,
            usesClearContentBackground: shouldUseClearContentBackground(
                opacity: config.backgroundOpacity,
                usesGhosttyGlassStyle: config.backgroundBlur.isMacOSGlassStyle,
                usesTransparentWindow: usesTransparentWindow
            )
        )
    }

    static func shouldUseClearContentBackground(
        opacity: Double,
        usesGhosttyGlassStyle: Bool,
        usesTransparentWindow: Bool
    ) -> Bool {
        usesTransparentWindow || usesGhosttyGlassStyle || opacity < 0.999
    }
}
