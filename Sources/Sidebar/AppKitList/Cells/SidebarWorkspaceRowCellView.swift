import AppKit
import Combine
import CmuxFoundation
import CmuxSidebar
import CmuxWorkspaces
import SwiftUI

/// Pure-AppKit workspace row cell: renders every TabItemView slot without
/// SwiftUI hosting. Subviews are created once (dynamic slots use view pools),
/// content applies in configure, and geometry resolves in one manual
/// layout pass shared with height measurement.
@MainActor
final class SidebarWorkspaceRowTableCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("SidebarWorkspaceRowTableCellView")

    // Chrome
    private let backgroundView = NSView()
    private let railView = NSView()
    private let topDropIndicator = NSView()
    private let bottomDropIndicator = NSView()
    private let hintPill = SidebarShortcutHintPillView()
    // Title line
    private let leadingBadge = SidebarRowUnreadBadgeView()
    private var leadingSpinner: GPUSpinnerNSView?
    private let pinImageView = NSImageView()
    private let mediaAudioView = NSImageView()
    private let mediaMicView = NSImageView()
    private let mediaCameraView = NSImageView()
    private let titleView = SidebarRowTextView(lines: 1)
    private let renameField = SidebarRowInlineRenameField()
    private let trailingBadge = SidebarRowUnreadBadgeView()
    private var trailingSpinner: GPUSpinnerNSView?
    private let closeButton = SidebarHeaderGlyphButton()
    // Detail slots
    private let descriptionView = SidebarRowTextView(lines: 12)
    private let subtitleView = SidebarRowTextView(lines: 2)
    private let remoteTargetView = SidebarRowTextView(lines: 1)
    private let remoteStatusView = SidebarRowTextView(lines: 1)
    private let remoteReconnectButton = NSButton()
    private var metadataRows: [SidebarRowIconTextLine] = []
    private var markdownBlocks: [SidebarRowTextView] = []
    private let logLine = SidebarRowIconTextLine()
    private let progressView = SidebarRowProgressView()
    private let branchIconView = NSImageView()
    private var branchLines: [SidebarRowIconTextLine] = []
    private var pullRequestRows: [SidebarRowPullRequestLine] = []
    private var portButtons: [SidebarRowLinkButton] = []
    private let checklistSection = SidebarRowChecklistSection()

    private var model: SidebarWorkspaceRowModel?
    private var actions: SidebarAppKitRowActions?
    private var isPointerHovering = false
    private var contextMenuVisible = false
    private var contextMenuDidOpen: (() -> Void)?
    private var contextMenuDidClose: (() -> Void)?
    private var isEditing = false
    private var pumpCancellables: [AnyCancellable] = []

    /// Per-row churn pump: mirrors TabItemView's onReceive subscriptions so
    /// metadata/branch/PR updates repaint just this cell without any
    /// container re-render. Installed per configure; replaced on reuse.
    func installPump(
        workspace: Workspace,
        rebuild: @escaping @MainActor () -> Void
    ) {
        pumpCancellables.removeAll()
        workspace.sidebarImmediateObservationPublisher
            .receive(on: RunLoop.main)
            .sink { _ in
                MainActor.assumeIsolated { rebuild() }
            }
            .store(in: &pumpCancellables)
        workspace.sidebarObservationPublisher
            .debounce(for: .milliseconds(40), scheduler: RunLoop.main)
            .sink { _ in
                MainActor.assumeIsolated { rebuild() }
            }
            .store(in: &pumpCancellables)
    }

    /// Measurement/apply entry used by the pump path.
    func applyRebuiltModel(_ model: SidebarWorkspaceRowModel) {
        guard self.model != model else { return }
        self.model = model
        applyModel(model)
        needsLayout = true
    }

    var currentModelForMeasurement: SidebarWorkspaceRowModel? { model }

    /// Paints the selected-row background instantly on press; the next
    /// authoritative configure() repaints the full selected treatment (or
    /// reverts if the selection did not land).
    func showOptimisticSelectionHighlight() {
        guard let model, !model.isActive else { return }
        let palette = SidebarRowPalette(model: model)
        backgroundView.layer?.backgroundColor = palette.selectedBackground.cgColor
        titleView.textColor = palette.selectedForeground(1.0)
    }

    /// Counterpart for the row selection is LEAVING: repaints the normal
    /// (deselected) treatment instantly so old and new selection never show
    /// together while the authoritative render sits behind the terminal-view
    /// swap. configure() reconciles right after.
    func showOptimisticDeselection() {
        guard let model, model.isActive || model.isMultiSelected else { return }
        let style = sidebarWorkspaceRowBackgroundStyle(
            activeTabIndicatorStyle: model.settings.activeTabIndicatorStyle,
            isActive: false,
            isMultiSelected: false,
            customColorHex: model.snapshot.customColorHex,
            colorScheme: SidebarRowPalette(model: model).colorScheme,
            sidebarSelectionColorHex: model.settings.selectionColorHex
        )
        applyBackgroundStyle(style)
        backgroundView.layer?.borderWidth = 0
        titleView.textColor = .labelColor
    }

    /// True when a press at this view should not repaint selection (the
    /// close button closes without selecting).
    func selectionPreviewShouldIgnore(_ hitView: NSView) -> Bool {
        hitView === closeButton || hitView.isDescendant(of: closeButton)
    }

    private func applyBackgroundStyle(_ style: SidebarWorkspaceRowBackgroundStyle) {
        backgroundView.layer?.backgroundColor = (style.color ?? .clear)
            .withAlphaComponent((style.color == nil ? 0 : style.opacity) * ((style.color?.alphaComponent) ?? 1)).cgColor
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
        wantsLayer = true
        layer?.masksToBounds = false

        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = 6
        backgroundView.layer?.cornerCurve = .continuous
        backgroundView.layer?.borderWidth = 0
        addSubview(backgroundView)
        railView.wantsLayer = true
        addSubview(railView)

        pinImageView.imageScaling = .scaleProportionallyDown
        addSubview(pinImageView)
        for view in [mediaAudioView, mediaMicView, mediaCameraView] {
            view.imageScaling = .scaleProportionallyDown
            addSubview(view)
        }
        addSubview(leadingBadge)
        addSubview(titleView)
        renameField.isHidden = true
        addSubview(renameField)
        addSubview(trailingBadge)
        closeButton.onClick = { [weak self] in self?.actions?.commands.closeWorkspace() }
        addSubview(closeButton)

        addSubview(descriptionView)
        addSubview(subtitleView)
        addSubview(remoteTargetView)
        addSubview(remoteStatusView)
        remoteReconnectButton.isBordered = false
        remoteReconnectButton.imagePosition = .imageLeading
        remoteReconnectButton.target = self
        remoteReconnectButton.action = #selector(didClickReconnect)
        addSubview(remoteReconnectButton)
        addSubview(logLine)
        addSubview(progressView)
        branchIconView.imageScaling = .scaleProportionallyDown
        addSubview(branchIconView)
        addSubview(checklistSection)

        topDropIndicator.wantsLayer = true
        bottomDropIndicator.wantsLayer = true
        addSubview(topDropIndicator)
        addSubview(bottomDropIndicator)
        addSubview(hintPill)

    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed {
            needsLayout = true
        }
    }

    // MARK: Configure

    func configure(
        model: SidebarWorkspaceRowModel,
        actions: SidebarAppKitRowActions,
        isPointerHovering: Bool,
        contextMenuDidOpen: @escaping () -> Void,
        contextMenuDidClose: @escaping () -> Void
    ) {
        let previous = self.model
        self.actions = actions
        self.contextMenuDidOpen = contextMenuDidOpen
        self.contextMenuDidClose = contextMenuDidClose
        let hoverChanged = self.isPointerHovering != isPointerHovering
        self.isPointerHovering = isPointerHovering
        if previous?.workspaceId != model.workspaceId {
            endInlineRename(commit: false)
        }
        guard previous != model || hoverChanged else { return }
        self.model = model
        applyModel(model)
        needsLayout = true
    }

    private func palette(_ model: SidebarWorkspaceRowModel) -> SidebarRowPalette {
        SidebarRowPalette(model: model)
    }

    private func applyModel(_ model: SidebarWorkspaceRowModel) {
        let palette = palette(model)
        let snapshot = model.snapshot
        let settings = model.settings

        // Chrome
        let style = sidebarWorkspaceRowBackgroundStyle(
            activeTabIndicatorStyle: settings.activeTabIndicatorStyle,
            isActive: model.isActive,
            isMultiSelected: model.isMultiSelected,
            customColorHex: snapshot.customColorHex,
            colorScheme: palette.colorScheme,
            sidebarSelectionColorHex: settings.selectionColorHex
        )
        applyBackgroundStyle(style)
        if settings.activeTabIndicatorStyle == .solidFill, model.isActive {
            backgroundView.layer?.borderWidth = 1.5
            backgroundView.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.5).cgColor
        } else {
            backgroundView.layer?.borderWidth = 0
        }
        let railColor = sidebarWorkspaceRowExplicitRailNSColor(
            activeTabIndicatorStyle: settings.activeTabIndicatorStyle,
            customColorHex: snapshot.customColorHex,
            colorScheme: palette.colorScheme
        )
        railView.isHidden = railColor == nil
        if let railColor {
            railView.layer?.backgroundColor = railColor.withAlphaComponent(0.95).cgColor
        }

        // Title line
        pinImageView.isHidden = !snapshot.isPinned
        if snapshot.isPinned {
            pinImageView.image = RenderableSystemSymbol.configuredAppKitImage(
                systemName: "pin.fill", pointSize: model.scaled(9), weight: .semibold
            )
            pinImageView.contentTintColor = palette.secondary(0.8)
            pinImageView.toolTip = String(localized: "sidebar.pinnedWorkspaceProtected.tooltip", defaultValue: "Pinned workspace — protected from Close")
        }
        let media = snapshot.mediaActivity
        mediaAudioView.isHidden = !media.isPlayingAudio
        if media.isPlayingAudio {
            mediaAudioView.image = RenderableSystemSymbol.configuredAppKitImage(
                systemName: "speaker.wave.2.fill", pointSize: model.scaled(9), weight: .semibold
            )
            mediaAudioView.contentTintColor = palette.secondary(0.8)
            mediaAudioView.toolTip = String(localized: "sidebar.mediaActivity.audio.tooltip", defaultValue: "Playing audio in a background browser")
        }
        mediaMicView.isHidden = !media.isUsingMicrophone
        if media.isUsingMicrophone {
            mediaMicView.image = RenderableSystemSymbol.configuredAppKitImage(
                systemName: "mic.fill", pointSize: model.scaled(9), weight: nil
            )
            mediaMicView.contentTintColor = .systemOrange
        }
        mediaCameraView.isHidden = !media.isUsingCamera
        if media.isUsingCamera {
            mediaCameraView.image = RenderableSystemSymbol.configuredAppKitImage(
                systemName: "video.fill", pointSize: model.scaled(9), weight: nil
            )
            mediaCameraView.contentTintColor = .systemGreen
        }

        let titleLineLimit = settings.wrapsWorkspaceTitles ? 8 : 1
        titleView.maximumNumberOfLines = titleLineLimit
        titleView.lineBreakMode = titleLineLimit == 1 ? .byTruncatingTail : .byWordWrapping
        titleView.stringValue = snapshot.title.sidebarBoundedDisplayString(
            maxDisplayedLines: titleLineLimit,
            maxDisplayedCharacters: 2048
        )
        titleView.font = .systemFont(ofSize: model.scaled(12.5), weight: .semibold)
        titleView.textColor = palette.primaryText

        // Badges / spinner / close
        let showsSpinner = model.showsAgentActivity && snapshot.activeCodingAgentCount > 0
        let badgeVisible = model.unreadCount > 0
        configureStatusSlot(
            model: model,
            palette: palette,
            badgeVisible: badgeVisible,
            spinnerVisible: showsSpinner
        )
        closeButton.glyphImage = RenderableSystemSymbol.configuredAppKitImage(
            systemName: "xmark", pointSize: model.scaled(9), weight: .medium
        )
        closeButton.contentTintColor = palette.secondary(0.7)
        closeButton.toolTip = snapshot.isPinned
            ? String(localized: "sidebar.pinnedWorkspaceProtected.tooltip", defaultValue: "Pinned workspace — protected from Close")
            : String(localized: "sidebar.closeWorkspace.tooltip", defaultValue: "Close workspace")
        updateCloseVisibility()

        // Description / subtitle
        let description = snapshot.customDescription
        descriptionView.isHidden = description == nil
        if let description {
            let display = description.sidebarBoundedDisplayString(maxDisplayedLines: 12, maxDisplayedCharacters: 4096)
            if let rendered = SidebarMarkdownRenderer(markdown: display).workspaceDescription {
                descriptionView.attributedStringValue = SidebarRowPalette.attributed(
                    rendered,
                    font: .systemFont(ofSize: model.scaled(10.5)),
                    color: model.isActive ? palette.secondary(0.84) : NSColor.secondaryLabelColor.withAlphaComponent(0.95)
                )
            } else {
                descriptionView.stringValue = display
                descriptionView.font = .systemFont(ofSize: model.scaled(10.5))
                descriptionView.textColor = model.isActive ? palette.secondary(0.84) : NSColor.secondaryLabelColor.withAlphaComponent(0.95)
            }
        }

        let conversationSubtitle: String? = {
            guard !settings.hidesAllDetails, settings.iMessageModeEnabled else { return nil }
            let trimmed = snapshot.latestConversationMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed?.isEmpty == false) ? trimmed : nil
        }()
        let effectiveSubtitle = model.latestNotificationText ?? conversationSubtitle
        let subtitleLineLimit = model.latestNotificationText == nil ? 2 : settings.notificationMessageLineLimit
        subtitleView.isHidden = effectiveSubtitle == nil
        if let effectiveSubtitle {
            subtitleView.maximumNumberOfLines = subtitleLineLimit
            subtitleView.stringValue = effectiveSubtitle.sidebarBoundedDisplayString(
                maxDisplayedLines: subtitleLineLimit,
                maxDisplayedCharacters: 4096
            )
            subtitleView.font = .systemFont(ofSize: model.scaled(10))
            subtitleView.textColor = palette.secondary(0.8)
        }

        // Remote
        let showsRemote = !settings.hidesAllDetails && settings.showsSSH && snapshot.remoteWorkspaceSidebarText != nil
        remoteTargetView.isHidden = !showsRemote
        remoteStatusView.isHidden = !showsRemote
        remoteReconnectButton.isHidden = !(showsRemote && snapshot.showsRemoteReconnectAffordance)
        if showsRemote {
            remoteTargetView.stringValue = snapshot.remoteWorkspaceSidebarText ?? ""
            remoteTargetView.font = .monospacedSystemFont(ofSize: model.scaled(10), weight: .regular)
            remoteTargetView.textColor = palette.secondary(0.8)
            remoteTargetView.lineBreakMode = .byTruncatingMiddle
            remoteTargetView.toolTip = snapshot.remoteStateHelpText
            remoteStatusView.stringValue = snapshot.remoteConnectionStatusText
            remoteStatusView.font = .systemFont(ofSize: model.scaled(9), weight: .medium)
            remoteStatusView.textColor = palette.secondary(0.58)
            if !remoteReconnectButton.isHidden {
                remoteReconnectButton.attributedTitle = NSAttributedString(
                    string: String(localized: "sidebar.remote.reconnect.button", defaultValue: "Reconnect"),
                    attributes: [
                        .font: NSFont.systemFont(ofSize: model.scaled(9), weight: .semibold),
                        .foregroundColor: palette.secondary(0.9),
                    ]
                )
                remoteReconnectButton.toolTip = String(localized: "sidebar.remote.reconnect.help", defaultValue: "Reconnect to the remote host")
            }
        }

        configureMetadata(model: model, palette: palette)
        configureLogAndProgress(model: model, palette: palette)
        configureBranchDirectory(model: model, palette: palette)
        configurePullRequestsAndPorts(model: model, palette: palette)
        if let actions {
            checklistSection.configure(model: model, palette: palette, actions: actions)
        }

        // Hint pill + indicators + dim/drag
        hintPill.configure(
            text: model.shortcutHintText,
            fontSize: model.scaled(10),
            emphasis: model.isActive ? 1.0 : 0.9
        )
        topDropIndicator.layer?.backgroundColor = cmuxAccentNSColor().cgColor
        bottomDropIndicator.layer?.backgroundColor = cmuxAccentNSColor().cgColor
        topDropIndicator.isHidden = !model.topDropIndicatorVisible
        bottomDropIndicator.isHidden = !model.bottomDropIndicatorVisible
        alphaValue = model.isBeingDragged ? 0.6 : 1

        setAccessibilityIdentifier("sidebarWorkspace.\(model.workspaceId.uuidString)")
        setAccessibilityLabel(String(
            localized: "accessibility.workspacePosition",
            defaultValue: "\(snapshot.title), workspace \(model.index + 1) of \(model.accessibilityWorkspaceCount)"
        ))
    }

    private func configureStatusSlot(
        model: SidebarWorkspaceRowModel,
        palette: SidebarRowPalette,
        badgeVisible: Bool,
        spinnerVisible: Bool
    ) {
        let badgeFill: NSColor = {
            if let hex = model.settings.notificationBadgeColorHex, let color = NSColor(hex: hex) {
                return color
            }
            return model.isActive ? palette.primaryText.withAlphaComponent(0.25) : cmuxAccentNSColor()
        }()
        let badgeText: NSColor = model.isActive ? palette.primaryText : .white
        let badgeFont = NSFont.systemFont(ofSize: model.scaled(9), weight: .semibold)

        let leadingBadgeVisible = badgeVisible && model.settings.notificationBadgePosition == .leading
        let trailingBadgeVisible = badgeVisible && model.settings.notificationBadgePosition == .trailing
        let leadingSpinnerVisible = spinnerVisible && model.settings.loadingSpinnerPosition == .leading
        let trailingSpinnerVisible = spinnerVisible && model.settings.loadingSpinnerPosition == .trailing

        leadingBadge.isHidden = !leadingBadgeVisible || leadingSpinnerVisible
        trailingBadge.isHidden = !trailingBadgeVisible || trailingSpinnerVisible || showsCloseNow
        if !leadingBadge.isHidden {
            leadingBadge.configure(count: model.unreadCount, fillColor: badgeFill, textColor: badgeText, font: badgeFont)
        }
        if !trailingBadge.isHidden {
            trailingBadge.configure(count: model.unreadCount, fillColor: badgeFill, textColor: badgeText, font: badgeFont)
        }

        let spinnerColor: NSColor = model.isActive
            ? palette.selectedForeground(0.55)
            : .secondaryLabelColor
        leadingSpinner = Self.updateSpinner(
            existing: leadingSpinner,
            visible: leadingSpinnerVisible,
            color: spinnerColor,
            in: self
        )
        trailingSpinner = Self.updateSpinner(
            existing: trailingSpinner,
            visible: trailingSpinnerVisible && !showsCloseNow,
            color: spinnerColor,
            in: self
        )
        let agentCount = model.snapshot.activeCodingAgentCount
        let tooltip = agentCount == 1
            ? String(localized: "sidebar.agentActivity.tooltip.one", defaultValue: "Loading (1 active task)")
            : String.localizedStringWithFormat(
                String(localized: "sidebar.agentActivity.tooltip.many", defaultValue: "Loading (%lld active tasks)"),
                agentCount
            )
        leadingSpinner?.toolTip = tooltip
        trailingSpinner?.toolTip = tooltip
    }

    private static func updateSpinner(
        existing: GPUSpinnerNSView?,
        visible: Bool,
        color: NSColor,
        in parent: NSView
    ) -> GPUSpinnerNSView? {
        if visible {
            let spinner = existing ?? GPUSpinnerNSView()
            spinner.style = .macOSSpokes
            spinner.color = color
            if spinner.superview == nil {
                parent.addSubview(spinner)
            }
            spinner.isHidden = false
            return spinner
        }
        existing?.isHidden = true
        return existing
    }

    private var showsCloseNow: Bool {
        guard let model else { return false }
        return isPointerHovering
            && !contextMenuVisible
            && model.canCloseWorkspace
            && !(model.showsShortcutHints || model.settings.alwaysShowShortcutHints)
    }

    private func updateCloseVisibility() {
        closeButton.setRevealed(showsCloseNow)
    }

    private func configureMetadata(model: SidebarWorkspaceRowModel, palette: SidebarRowPalette) {
        let entries = model.snapshot.metadataEntries
        let visible = model.settings.visibleAuxiliaryDetails.showsMetadata ? Array(entries.prefix(3)) : []
        Self.pool(&metadataRows, count: visible.count, parent: self) { SidebarRowIconTextLine() }
        for (index, entry) in visible.enumerated() {
            metadataRows[index].configureMetadataEntry(
                entry, model: model,
                color: entry.color.flatMap { NSColor(hex: $0) } ?? (model.isActive ? palette.secondary(0.95).withAlphaComponent(0.84) : .secondaryLabelColor)
            )
        }
        let blocks = model.settings.visibleAuxiliaryDetails.showsMetadata ? Array(model.snapshot.metadataBlocks.prefix(1)) : []
        Self.pool(&markdownBlocks, count: blocks.count, parent: self) { SidebarRowTextView(lines: 12) }
        for (index, block) in blocks.enumerated() {
            let view = markdownBlocks[index]
            let display = block.markdown.sidebarBoundedDisplayString(maxDisplayedLines: 12, maxDisplayedCharacters: 4096)
            if let rendered = SidebarMetadataMarkdownRenderer.rendered(display) {
                view.attributedStringValue = SidebarRowPalette.attributed(
                    rendered,
                    font: .systemFont(ofSize: model.scaled(10)),
                    color: model.isActive ? palette.secondary(0.8) : .secondaryLabelColor
                )
            } else {
                view.stringValue = display
                view.font = .systemFont(ofSize: model.scaled(10))
                view.textColor = model.isActive ? palette.secondary(0.8) : .secondaryLabelColor
            }
        }
    }

    private func configureLogAndProgress(model: SidebarWorkspaceRowModel, palette: SidebarRowPalette) {
        let log = model.settings.visibleAuxiliaryDetails.showsLog ? model.snapshot.latestLog : nil
        logLine.isHidden = log == nil
        if let log {
            logLine.configureLog(log, model: model, palette: palette)
        }
        let progress = model.settings.visibleAuxiliaryDetails.showsProgress ? model.snapshot.progress : nil
        progressView.isHidden = progress == nil
        if let progress {
            let labelFont = NSFont.systemFont(ofSize: model.scaled(9))
            progressView.configure(
                fraction: CGFloat(progress.value),
                barHeight: max(3, 3 * model.fontScale),
                trackColor: model.isActive ? palette.selectedForeground(0.15) : NSColor.secondaryLabelColor.withAlphaComponent(0.2),
                fillColor: model.isActive ? palette.selectedForeground(0.8) : cmuxAccentNSColor(),
                labelText: progress.label,
                labelFont: labelFont,
                labelColor: palette.secondary(0.6)
            )
        }
    }

    private func configureBranchDirectory(model: SidebarWorkspaceRowModel, palette: SidebarRowPalette) {
        let snapshot = model.snapshot
        let settings = model.settings
        let showsSection = settings.visibleAuxiliaryDetails.showsBranchDirectory
        var lines: [SidebarRowIconTextLine.BranchLineContent] = []
        if showsSection {
            if settings.usesVerticalBranchLayout {
                for line in snapshot.branchDirectoryLines {
                    lines.append(.init(
                        branch: settings.showsGitBranch ? line.branch : nil,
                        directoryCandidates: line.directoryCandidates,
                        stacked: settings.stacksBranchAndDirectory
                    ))
                }
            } else if settings.stacksBranchAndDirectory {
                if snapshot.compactGitBranchSummaryText != nil || !snapshot.compactDirectoryCandidates.isEmpty {
                    lines.append(.init(
                        branch: snapshot.compactGitBranchSummaryText,
                        directoryCandidates: snapshot.compactDirectoryCandidates,
                        stacked: true
                    ))
                }
            } else if !snapshot.compactBranchDirectoryCandidates.isEmpty {
                lines.append(.init(
                    branch: nil,
                    directoryCandidates: snapshot.compactBranchDirectoryCandidates,
                    stacked: false
                ))
            }
        }
        let showsIcon = showsSection && settings.showsGitBranchIcon
            && (settings.usesVerticalBranchLayout ? snapshot.branchLinesContainBranch : snapshot.compactGitBranchSummaryText != nil || !snapshot.compactBranchDirectoryCandidates.isEmpty)
        branchIconView.isHidden = !(showsIcon && !lines.isEmpty)
        if !branchIconView.isHidden {
            branchIconView.image = RenderableSystemSymbol.configuredAppKitImage(
                systemName: "arrow.triangle.branch", pointSize: model.scaled(9), weight: nil
            )
            branchIconView.contentTintColor = palette.secondary(0.6)
        }
        Self.pool(&branchLines, count: lines.count, parent: self) { SidebarRowIconTextLine() }
        for (index, content) in lines.enumerated() {
            branchLines[index].configureBranchLine(content, model: model, palette: palette)
        }
    }

    private func configurePullRequestsAndPorts(model: SidebarWorkspaceRowModel, palette: SidebarRowPalette) {
        let snapshot = model.snapshot
        let settings = model.settings
        let prs = settings.visibleAuxiliaryDetails.showsPullRequests ? snapshot.pullRequestRows : []
        Self.pool(&pullRequestRows, count: prs.count, parent: self) { SidebarRowPullRequestLine() }
        for (index, pr) in prs.enumerated() {
            pullRequestRows[index].configure(
                pr, model: model, palette: palette,
                clickable: settings.makesPullRequestsClickable
            ) { [weak self] in
                self?.actions?.commands.updateSelection()
                self?.actions?.onOpenPullRequest(pr.url)
            }
        }
        let ports = settings.visibleAuxiliaryDetails.showsPorts ? snapshot.listeningPorts : []
        Self.pool(&portButtons, count: ports.count, parent: self) { SidebarRowLinkButton() }
        for (index, port) in ports.enumerated() {
            portButtons[index].configure(
                title: SidebarPortDisplayText.label(for: port),
                font: .monospacedSystemFont(ofSize: model.scaled(10), weight: .regular),
                color: palette.secondary(0.75),
                underlined: true,
                toolTip: String(localized: "sidebar.port.openTooltip", defaultValue: "Open localhost port")
            ) { [weak self] in
                self?.actions?.commands.updateSelection()
                self?.actions?.onOpenPort(port)
            }
        }
    }

    private static func pool<View: NSView>(
        _ views: inout [View],
        count: Int,
        parent: NSView,
        make: () -> View
    ) {
        while views.count < count {
            let view = make()
            parent.addSubview(view)
            views.append(view)
        }
        for (index, view) in views.enumerated() {
            view.isHidden = index >= count
        }
    }

    // MARK: Interaction

    @objc private func didClickReconnect() {
        actions?.commands.reconnectRemoteConnection()
    }

    func beginInlineRename() {
        guard let model else { return }
        isEditing = true
        renameField.stringValue = model.snapshot.title
        renameField.font = .systemFont(ofSize: model.scaled(12.5), weight: .semibold)
        renameField.textColor = palette(model).selectedForeground(1.0)
        renameField.isHidden = false
        titleView.isHidden = true
        renameField.onCommit = { [weak self] text in
            self?.actions?.commitRename(text)
            self?.endInlineRename(commit: true)
        }
        renameField.onCancel = { [weak self] in
            self?.endInlineRename(commit: false)
        }
        window?.makeFirstResponder(renameField)
        renameField.selectText(nil)
        needsLayout = true
    }

    private func endInlineRename(commit: Bool) {
        guard isEditing else { return }
        isEditing = false
        renameField.isHidden = true
        titleView.isHidden = false
        needsLayout = true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let actions else { return nil }
        return actions.commands.makeContextMenu(
            onOpen: { [weak self] in
                self?.contextMenuVisible = true
                self?.updateCloseVisibility()
                self?.contextMenuDidOpen?()
            },
            onClose: { [weak self] in
                self?.contextMenuVisible = false
                self?.updateCloseVisibility()
                self?.contextMenuDidClose?()
            }
        )
    }

    // MARK: Layout + measurement

    override func layout() {
        super.layout()
        guard let model else { return }
        _ = layoutContent(model: model, width: bounds.width, apply: true)
    }

    /// Places (or measures) every slot top-down; single source of truth for
    /// row height. Returns total height including vertical padding.
    @discardableResult
    func layoutContent(model: SidebarWorkspaceRowModel, width: CGFloat, apply: Bool) -> CGFloat {
        let outerPad = SidebarWorkspaceListMetrics.rowOuterHorizontalPadding
        let contentPad = SidebarWorkspaceListMetrics.rowContentHorizontalPadding
        let leading = outerPad + contentPad + (model.isGrouped ? SidebarWorkspaceGroupingMetrics.memberIndent : 0)
        let trailing = width - outerPad - contentPad
        let contentWidth = max(10, trailing - leading)
        var y: CGFloat = 8
        let spacing: CGFloat = 4

        // Title line
        let titleRowSpacing: CGFloat = (model.settings.loadingSpinnerPosition == .leading
            && model.showsAgentActivity && model.snapshot.activeCodingAgentCount > 0) ? 6 : 8
        var x = leading
        let badgeSide = 16 * model.fontScale
        let spinnerSide = max(10, 12 * model.fontScale)
        let firstLineCenter = model.scaled(12.5) * 0.6 + y

        func place(_ view: NSView, size: NSSize, centerY: CGFloat) {
            guard apply else { return }
            view.frame = NSRect(
                x: x, y: centerY - size.height / 2,
                width: size.width, height: size.height
            )
        }

        let leadingSlotActive = (!leadingBadge.isHidden) || (leadingSpinner?.isHidden == false)
        if leadingSlotActive {
            let side = !leadingBadge.isHidden ? badgeSide : spinnerSide
            if !leadingBadge.isHidden {
                place(leadingBadge, size: NSSize(width: side, height: side), centerY: firstLineCenter)
            }
            if let spinner = leadingSpinner, !spinner.isHidden {
                place(spinner, size: NSSize(width: spinnerSide, height: spinnerSide), centerY: firstLineCenter)
            }
            x += side + titleRowSpacing
        }
        if !pinImageView.isHidden {
            let side = model.scaled(9) + 4
            place(pinImageView, size: NSSize(width: side, height: side), centerY: firstLineCenter)
            x += side + titleRowSpacing
        }
        for view in [mediaAudioView, mediaMicView, mediaCameraView] where !view.isHidden {
            let side = model.scaled(9) + 4
            place(view, size: NSSize(width: side, height: side), centerY: firstLineCenter)
            x += side + titleRowSpacing
        }

        // Trailing slot
        let closeHit = max(16, 16 * model.fontScale)
        let closeWidth = max(16, closeHit)
        let trailingSlotActive = !trailingBadge.isHidden || (trailingSpinner?.isHidden == false) || model.canCloseWorkspace
        let titleMaxX = trailingSlotActive ? (trailing - closeWidth - titleRowSpacing) : trailing
        let titleWidth = max(10, titleMaxX - x)
        let titleHeight = isEditing
            ? ceil(renameField.intrinsicContentSize.height)
            : titleView.measuredHeight(width: titleWidth)
        if apply {
            let frame = NSRect(x: x, y: y, width: titleWidth, height: titleHeight)
            if isEditing {
                renameField.frame = frame
            } else {
                titleView.frame = frame
            }
            if trailingSlotActive {
                let slotX = trailing - closeWidth
                closeButton.frame = NSRect(
                    x: slotX, y: firstLineCenter - closeHit / 2, width: closeWidth, height: closeHit
                )
                if !trailingBadge.isHidden {
                    trailingBadge.frame = NSRect(
                        x: trailing - badgeSide, y: firstLineCenter - badgeSide / 2,
                        width: badgeSide, height: badgeSide
                    )
                }
                if let spinner = trailingSpinner, !spinner.isHidden {
                    spinner.frame = NSRect(
                        x: trailing - spinnerSide, y: firstLineCenter - spinnerSide / 2,
                        width: spinnerSide, height: spinnerSide
                    )
                }
            }
        }
        y += max(titleHeight, leadingSlotActive ? badgeSide : 0)

        func placeBlock(_ view: SidebarRowTextView) {
            guard !view.isHidden else { return }
            y += spacing
            let height = view.measuredHeight(width: contentWidth)
            if apply {
                view.frame = NSRect(x: leading, y: y, width: contentWidth, height: height)
            }
            y += height
        }

        placeBlock(descriptionView)
        placeBlock(subtitleView)

        if !remoteTargetView.isHidden {
            y += model.latestNotificationText == nil ? 1 : 2
            y += spacing
            let statusSize = remoteStatusView.isHidden ? .zero : remoteStatusView.intrinsicContentSize
            let reconnectSize = remoteReconnectButton.isHidden ? .zero : remoteReconnectButton.intrinsicContentSize
            let rightWidth = statusSize.width + (reconnectSize.width > 0 ? reconnectSize.width + 6 : 0)
            let targetWidth = max(10, contentWidth - rightWidth - 6)
            let lineHeight = max(remoteTargetView.intrinsicContentSize.height, statusSize.height, reconnectSize.height)
            if apply {
                remoteTargetView.frame = NSRect(x: leading, y: y, width: targetWidth, height: lineHeight)
                var rightX = trailing - statusSize.width
                if !remoteReconnectButton.isHidden {
                    rightX = trailing - reconnectSize.width
                    remoteReconnectButton.frame = NSRect(x: rightX, y: y, width: reconnectSize.width, height: lineHeight)
                    rightX -= statusSize.width + 6
                }
                remoteStatusView.frame = NSRect(x: rightX, y: y, width: statusSize.width, height: lineHeight)
            }
            y += lineHeight
        }

        for row in metadataRows where !row.isHidden {
            y += 2
            let height = row.measuredHeight(width: contentWidth)
            if apply { row.frame = NSRect(x: leading, y: y, width: contentWidth, height: height) }
            y += height
        }
        for block in markdownBlocks where !block.isHidden {
            y += 3
            let height = block.measuredHeight(width: contentWidth)
            if apply { block.frame = NSRect(x: leading, y: y, width: contentWidth, height: height) }
            y += height
        }
        if !logLine.isHidden {
            y += spacing
            let height = logLine.measuredHeight(width: contentWidth)
            if apply { logLine.frame = NSRect(x: leading, y: y, width: contentWidth, height: height) }
            y += height
        }
        if !progressView.isHidden {
            y += spacing
            let height = SidebarRowProgressView.height(
                barHeight: max(3, 3 * model.fontScale),
                labelText: model.snapshot.progress?.label,
                labelFont: .systemFont(ofSize: model.scaled(9))
            )
            if apply { progressView.frame = NSRect(x: leading, y: y, width: contentWidth, height: height) }
            y += height
        }

        let visibleBranchLines = branchLines.filter { !$0.isHidden }
        if !visibleBranchLines.isEmpty {
            y += spacing
            var lineX = leading
            if !branchIconView.isHidden {
                let side = model.scaled(9) + 3
                if apply {
                    branchIconView.frame = NSRect(x: leading, y: y, width: side, height: side)
                }
                lineX += side + 3
            }
            let lineWidth = max(10, trailing - lineX)
            for line in visibleBranchLines {
                let height = line.measuredHeight(width: lineWidth)
                if apply { line.frame = NSRect(x: lineX, y: y, width: lineWidth, height: height) }
                y += height + 1
            }
            y -= 1
        }

        let visiblePRs = pullRequestRows.filter { !$0.isHidden }
        if !visiblePRs.isEmpty {
            y += spacing
            for row in visiblePRs {
                let height = row.measuredHeight(width: contentWidth)
                if apply { row.frame = NSRect(x: leading, y: y, width: contentWidth, height: height) }
                y += height + 1
            }
            y -= 1
        }

        let visiblePorts = portButtons.filter { !$0.isHidden }
        if !visiblePorts.isEmpty {
            y += spacing
            var portX = leading
            var lineHeight: CGFloat = 0
            for button in visiblePorts {
                let size = button.intrinsicContentSize
                if portX > leading, portX + size.width > trailing {
                    // Wrap to a new line instead of laying ports past the
                    // row's trailing edge (unbounded growth with many ports).
                    y += lineHeight + 4
                    portX = leading
                    lineHeight = 0
                }
                if apply { button.frame = NSRect(x: portX, y: y, width: size.width, height: size.height) }
                portX += size.width + 4
                lineHeight = max(lineHeight, size.height)
            }
            y += lineHeight
        }

        if !checklistSection.isHidden {
            y += spacing
            let height = checklistSection.measuredHeight(width: contentWidth)
            if apply { checklistSection.frame = NSRect(x: leading, y: y, width: contentWidth, height: height) }
            y += height
        }

        y += 8

        if apply {
            let bgX = outerPad
            backgroundView.frame = NSRect(x: bgX, y: 0, width: width - outerPad * 2, height: y)
            railView.frame = NSRect(x: bgX + 4 - 1, y: 5, width: 3, height: max(0, y - 10))
            railView.layer?.cornerRadius = 1.5
            let indicatorLeading: CGFloat = 8 + (model.isGrouped ? 0 : 0)
            topDropIndicator.frame = NSRect(
                x: indicatorLeading,
                y: model.isFirstRow ? 0 : -(model.rowSpacing / 2),
                width: max(0, width - indicatorLeading - 8), height: 2
            )
            bottomDropIndicator.frame = NSRect(
                x: indicatorLeading,
                y: y - 2 + model.rowSpacing / 2,
                width: max(0, width - indicatorLeading - 8), height: 2
            )
            let pillSize = hintPill.fittingPillSize()
            hintPill.frame = NSRect(
                x: width - pillSize.width - 10 + ShortcutHintDebugSettings.clamped(model.settings.sidebarShortcutHintXOffset),
                y: 6 + ShortcutHintDebugSettings.clamped(model.settings.sidebarShortcutHintYOffset),
                width: pillSize.width, height: pillSize.height
            )
        }
        return ceil(y)
    }
}

/// Borderless single-line rename field (select-all on focus, Escape cancels).
@MainActor
final class SidebarRowInlineRenameField: NSTextField, NSTextFieldDelegate {
    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?

    init() {
        super.init(frame: .zero)
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        usesSingleLineMode = true
        lineBreakMode = .byTruncatingTail
        delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onCancel?()
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            onCommit?(stringValue)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard !isHidden else { return }
        onCommit?(stringValue)
    }
}
