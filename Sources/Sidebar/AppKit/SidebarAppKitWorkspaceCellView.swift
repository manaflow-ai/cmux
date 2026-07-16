import AppKit
import CmuxFoundation
import CmuxSettings
import CmuxWorkspaces

/// Reusable native cell for one immutable workspace-row projection.
///
/// The view hierarchy is created once. `configure(snapshot:actions:)` only
/// updates retained AppKit controls, which keeps reuse predictable when the
/// sidebar contains hundreds of frequently changing workspaces.
@MainActor
final class SidebarAppKitWorkspaceCellView: NSTableCellView, NSTextFieldDelegate {
    struct Actions {
        let onActivate: () -> Void
        let onMoveUp: () -> Void
        let onMoveDown: () -> Void
        let onCommitRename: (String) -> Void
        let onClose: () -> Void
        let onOpenMetadataURL: (URL) -> Void
        let onOpenPullRequest: (URL) -> Void
        let onOpenPort: (Int) -> Void
        let checklistStyle: WorkspaceTodoChecklistStyle
        let onOpenChecklist: (NSView) -> Void
        let resolveChecklistWorkspace: () -> Workspace?
        let onChecklistHeightChanged: () -> Void
        let onReconnectRemote: () -> Void
        let onCopyRemoteError: (String) -> Void

        init(
            onActivate: @escaping () -> Void,
            onMoveUp: @escaping () -> Void,
            onMoveDown: @escaping () -> Void,
            onCommitRename: @escaping (String) -> Void,
            onClose: @escaping () -> Void,
            onOpenMetadataURL: @escaping (URL) -> Void,
            onOpenPullRequest: @escaping (URL) -> Void,
            onOpenPort: @escaping (Int) -> Void,
            checklistStyle: WorkspaceTodoChecklistStyle,
            onOpenChecklist: @escaping (NSView) -> Void,
            resolveChecklistWorkspace: @escaping () -> Workspace?,
            onChecklistHeightChanged: @escaping () -> Void,
            onReconnectRemote: @escaping () -> Void,
            onCopyRemoteError: @escaping (String) -> Void
        ) {
            self.onActivate = onActivate
            self.onMoveUp = onMoveUp
            self.onMoveDown = onMoveDown
            self.onCommitRename = onCommitRename
            self.onClose = onClose
            self.onOpenMetadataURL = onOpenMetadataURL
            self.onOpenPullRequest = onOpenPullRequest
            self.onOpenPort = onOpenPort
            self.checklistStyle = checklistStyle
            self.onOpenChecklist = onOpenChecklist
            self.resolveChecklistWorkspace = resolveChecklistWorkspace
            self.onChecklistHeightChanged = onChecklistHeightChanged
            self.onReconnectRemote = onReconnectRemote
            self.onCopyRemoteError = onCopyRemoteError
        }

        static let none = Self(
            onActivate: {},
            onMoveUp: {},
            onMoveDown: {},
            onCommitRename: { _ in },
            onClose: {},
            onOpenMetadataURL: { _ in },
            onOpenPullRequest: { _ in },
            onOpenPort: { _ in },
            checklistStyle: .popover,
            onOpenChecklist: { _ in },
            resolveChecklistWorkspace: { nil },
            onChecklistHeightChanged: {},
            onReconnectRemote: {},
            onCopyRemoteError: { _ in }
        )
    }

    private struct RenameSession {
        let workspaceID: UUID
        let baselineTitle: String
        let baselineHadUserCustomTitle: Bool
    }

    private let backgroundView = NSView()
    private let railView = NSView()
    private let topDropIndicator = NSView()
    private let bottomDropIndicator = NSView()
    private let contentStack = NSStackView()
    private let titleRow = NSStackView()
    private let leadingBadge = SidebarAppKitBadgeView()
    private let leadingSpinner = GPUSpinnerNSView(frame: .zero)
    private let pinImageView = NSImageView()
    private let mediaImageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let renameField = NSTextField(string: "")
    private let trailingSpinner = GPUSpinnerNSView(frame: .zero)
    private let trailingBadge = SidebarAppKitBadgeView()
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let descriptionLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let remoteRow = NSStackView()
    private let remoteLabel = NSTextField(labelWithString: "")
    private let remoteStatusLabel = NSTextField(labelWithString: "")
    private let remoteReconnectButton = NSButton()
    private let detailsView = SidebarAppKitWorkspaceDetailsView(frame: .zero)
    private let progressStack = NSStackView()
    private let progressIndicator = NSProgressIndicator()
    private let progressLabel = NSTextField(labelWithString: "")
    private let checklistButton = NSButton()
    private var inlineChecklistView: SidebarAppKitChecklistView?

    private var snapshot: SidebarWorkspaceRowSnapshot?
    private var actions = Actions.none
    private var copyableRemoteError: String?
    private var isPointerInside = false
    private var pointerTrackingArea: NSTrackingArea?
    private var selectedBackgroundColor: NSColor?
    private var badgeFillColor: NSColor = .controlAccentColor
    private let renameKeyResolver = SidebarInlineRenameKeyResolver()
    private var renameSession: RenameSession?
    private var renameHasMovedCaretToStart = false
    private var fontMagnificationObserver: GlobalFontMagnificationChangeObserver?
    private lazy var moveUpAccessibilityAction = NSAccessibilityCustomAction(
        name: String(localized: "sidebar.workspace.moveUpAction", defaultValue: "Move Up"),
        target: self,
        selector: #selector(moveUpForAccessibility)
    )
    private lazy var moveDownAccessibilityAction = NSAccessibilityCustomAction(
        name: String(localized: "sidebar.workspace.moveDownAction", defaultValue: "Move Down"),
        target: self,
        selector: #selector(moveDownForAccessibility)
    )
    private lazy var copyRemoteErrorAccessibilityAction = NSAccessibilityCustomAction(
        name: String(localized: "contextMenu.copySshError", defaultValue: "Copy SSH Error"),
        target: self,
        selector: #selector(copyRemoteErrorForAccessibility)
    )

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUpHierarchy()
        setUpAccessibility()
        resetForReuse()
        fontMagnificationObserver = GlobalFontMagnificationChangeObserver { [weak self] in
            self?.refreshFontMagnification()
        }
    }

    convenience init(identifier: NSUserInterfaceItemIdentifier) {
        self.init(frame: .zero)
        self.identifier = identifier
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// Applies one immutable projection without replacing any subviews.
    func configure(snapshot: SidebarWorkspaceRowSnapshot, actions: Actions) {
        if let renameSession, renameSession.workspaceID != snapshot.workspaceId {
            discardInlineRename(resignFirstResponder: true)
        }
        self.snapshot = snapshot
        self.actions = actions

        let workspace = snapshot.workspace
        let scale = max(0.5, snapshot.settings.sidebarFontScale)
        closeButton.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: GlobalFontMagnification.scaledSize(9 * scale),
            weight: .medium
        )
        let titleLineCount = snapshot.settings.wrapsWorkspaceTitles ? 8 : 1
        let title = SidebarAppKitCellText.bounded(
            workspace.title,
            maximumCharacters: 2_048,
            maximumLines: titleLineCount
        ) ?? workspace.title

        titleLabel.stringValue = title
        titleLabel.maximumNumberOfLines = titleLineCount
        titleLabel.lineBreakMode = snapshot.settings.wrapsWorkspaceTitles ? .byWordWrapping : .byTruncatingTail
        titleLabel.font = GlobalFontMagnification.systemFont(
            ofSize: 12.5 * scale,
            weight: .semibold
        )
        titleLabel.toolTip = workspace.title
        renameField.font = titleLabel.font

        configurePin(workspace.isPinned, scale: scale)
        configureMediaActivity(workspace.mediaActivity, scale: scale)
        configureSubtitle(snapshot: snapshot, scale: scale)
        configureRemoteDetail(snapshot: snapshot, scale: scale)
        configureAuxiliaryDetails(snapshot: snapshot, scale: scale)
        configureProgress(snapshot: snapshot, scale: scale)
        configureChecklist(snapshot: snapshot, scale: scale)
        configureInlineChecklist(snapshot: snapshot)
        configureStatusAccessories(snapshot: snapshot, scale: scale)
        configureColors(snapshot: snapshot)
        configureAccessibility(snapshot: snapshot)

        backgroundView.alphaValue = (snapshot.isBeingDragged || workspace.taskStatus == .done) ? 0.6 : 1
        topDropIndicator.isHidden = !snapshot.topDropIndicatorVisible
        bottomDropIndicator.isHidden = !snapshot.bottomDropIndicatorVisible
        isPointerInside = snapshot.isPointerHovering
        updateTrailingAccessoryVisibility()
        updateDropIndicatorColors()
        needsLayout = true
    }

    /// Clears model-derived content and callbacks before a cell enters reuse.
    func resetForReuse() {
        discardInlineRename(resignFirstResponder: true)
        snapshot = nil
        actions = .none
        copyableRemoteError = nil
        isPointerInside = false
        selectedBackgroundColor = nil
        badgeFillColor = .controlAccentColor

        titleLabel.stringValue = ""
        titleLabel.toolTip = nil
        titleLabel.isHidden = false
        renameField.stringValue = ""
        renameField.isHidden = true
        descriptionLabel.stringValue = ""
        descriptionLabel.isHidden = true
        subtitleLabel.stringValue = ""
        subtitleLabel.isHidden = true
        remoteRow.toolTip = nil
        remoteRow.isHidden = true
        remoteRow.setAccessibilityLabel(nil)
        remoteRow.setAccessibilityValue(nil)
        remoteLabel.stringValue = ""
        remoteLabel.toolTip = nil
        remoteStatusLabel.stringValue = ""
        remoteStatusLabel.toolTip = nil
        remoteReconnectButton.toolTip = nil
        remoteReconnectButton.isHidden = true
        remoteReconnectButton.setAccessibilityHelp(nil)
        setAccessibilityCustomActions(nil)
        detailsView.resetForReuse()
        progressLabel.stringValue = ""
        progressLabel.isHidden = true
        progressIndicator.doubleValue = 0
        progressStack.isHidden = true
        checklistButton.title = ""
        checklistButton.attributedTitle = NSAttributedString(string: "")
        checklistButton.image = nil
        checklistButton.toolTip = nil
        checklistButton.isHidden = true
        inlineChecklistView?.stopObserving()
        inlineChecklistView?.isHidden = true

        leadingBadge.resetForReuse()
        trailingBadge.resetForReuse()
        leadingSpinner.isHidden = true
        leadingSpinner.toolTip = nil
        trailingSpinner.isHidden = true
        trailingSpinner.toolTip = nil
        pinImageView.isHidden = true
        pinImageView.toolTip = nil
        mediaImageView.isHidden = true
        mediaImageView.toolTip = nil
        shortcutLabel.stringValue = ""
        shortcutLabel.isHidden = true
        closeButton.isHidden = true
        closeButton.toolTip = nil

        backgroundView.alphaValue = 1
        backgroundView.layer?.backgroundColor = nil
        backgroundView.layer?.borderColor = nil
        backgroundView.layer?.borderWidth = 0
        railView.isHidden = true
        railView.layer?.backgroundColor = nil
        topDropIndicator.isHidden = true
        bottomDropIndicator.isHidden = true
        setAccessibilityIdentifier(nil)
        setAccessibilityLabel(nil)
        setAccessibilityValue(nil)
        setAccessibilitySelected(false)
    }

    /// Returns the Auto Layout fitting height for the proposed table width.
    func fittingHeight(constrainedTo width: CGFloat) -> CGFloat {
        let horizontalInsets = 2 * (
            SidebarAppKitCellMetrics.outerHorizontalInset
                + SidebarAppKitCellMetrics.innerHorizontalInset
        )
        let available = max(1, width - horizontalInsets)
        titleLabel.preferredMaxLayoutWidth = available
        descriptionLabel.preferredMaxLayoutWidth = available
        subtitleLabel.preferredMaxLayoutWidth = available
        remoteLabel.preferredMaxLayoutWidth = available
        layoutSubtreeIfNeeded()
        return ceil(max(
            SidebarAppKitCellMetrics.minimumWorkspaceHeight,
            contentStack.fittingSize.height + 2 * SidebarAppKitCellMetrics.verticalInset
        ))
    }

    override func updateTrackingAreas() {
        if let pointerTrackingArea {
            removeTrackingArea(pointerTrackingArea)
        }
        let options: NSTrackingArea.Options = [
            .mouseEnteredAndExited,
            .activeInKeyWindow,
            .inVisibleRect,
        ]
        let area = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        pointerTrackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        updateTrailingAccessoryVisibility()
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        updateTrailingAccessoryVisibility()
    }

    /// Interactive descendants keep their own events. Ordinary row hits go to
    /// `NSTableView`, which owns selection, modifier handling, context menus,
    /// middle-clicks, and drag-session tracking.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hitView = super.hitTest(point) else { return nil }
        if let currentEvent = NSApp.currentEvent {
            let routesToRow = currentEvent.type == .rightMouseDown
                || currentEvent.type == .otherMouseDown
                || (currentEvent.type == .leftMouseDown
                    && currentEvent.modifierFlags.contains(.control))
            if routesToRow {
                return enclosingTableView ?? hitView
            }
        }
        if belongsToInteractiveSubview(hitView, ancestor: closeButton)
            || belongsToInteractiveSubview(hitView, ancestor: renameField)
            || belongsToInteractiveSubview(hitView, ancestor: checklistButton)
            || inlineChecklistView.map({ belongsToInteractiveSubview(hitView, ancestor: $0) }) == true
            || belongsToInteractiveSubview(hitView, ancestor: remoteReconnectButton)
            || detailsView.containsInteractiveDescendant(hitView) {
            return hitView
        }
        if NSApp.currentEvent?.type == .leftMouseDown,
           (NSApp.currentEvent?.clickCount ?? 0) >= 2 {
            return self
        }
        return enclosingTableView ?? hitView
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            beginInlineRename()
            return
        }
        if let enclosingTableView {
            enclosingTableView.mouseDown(with: event)
        } else {
            super.mouseDown(with: event)
        }
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard control === renameField, renameSession != nil else { return false }
        guard !textView.hasMarkedText() else { return false }

        switch renameKeyResolver.action(
            for: commandSelector,
            hasMovedCaretToStart: renameHasMovedCaretToStart
        ) {
        case .commit:
            commitInlineRename(textView.string, resignFirstResponder: true)
            return true
        case .caretToStart:
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            renameHasMovedCaretToStart = true
            return true
        case .cancel:
            discardInlineRename(resignFirstResponder: true)
            return true
        case .passThrough:
            return false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              field === renameField else { return }
        commitInlineRename(renameField.stringValue, resignFirstResponder: false)
    }

    override func accessibilityPerformPress() -> Bool {
        actions.onActivate()
        return true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard let snapshot else { return }
        configureAuxiliaryDetails(
            snapshot: snapshot,
            scale: max(0.5, snapshot.settings.sidebarFontScale)
        )
        configureColors(snapshot: snapshot)
        updateDropIndicatorColors()
    }

    private func setUpHierarchy() {
        wantsLayer = true
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = SidebarAppKitCellMetrics.cornerRadius
        backgroundView.layer?.masksToBounds = false
        addSubview(backgroundView)

        railView.translatesAutoresizingMaskIntoConstraints = false
        railView.wantsLayer = true
        railView.layer?.cornerRadius = SidebarAppKitCellMetrics.railWidth / 2
        backgroundView.addSubview(railView)

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.distribution = .fill
        contentStack.spacing = SidebarAppKitCellMetrics.rowSpacing
        backgroundView.addSubview(contentStack)

        setUpTitleRow()
        setUpTextLabel(descriptionLabel, maximumLines: 3)
        setUpTextLabel(subtitleLabel, maximumLines: 2)
        setUpRemoteRow()
        setUpProgress()
        setUpChecklist()
        detailsView.onHeightChanged = { [weak self] in
            self?.actions.onChecklistHeightChanged()
        }

        [
            titleRow,
            descriptionLabel,
            subtitleLabel,
            remoteRow,
            detailsView,
            progressStack,
            checklistButton,
        ].forEach {
            contentStack.addArrangedSubview($0)
            $0.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }

        setUpDropIndicator(topDropIndicator)
        setUpDropIndicator(bottomDropIndicator)
        addSubview(topDropIndicator)
        addSubview(bottomDropIndicator)

        NSLayoutConstraint.activate([
            backgroundView.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: SidebarAppKitCellMetrics.outerHorizontalInset
            ),
            backgroundView.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -SidebarAppKitCellMetrics.outerHorizontalInset
            ),
            backgroundView.topAnchor.constraint(equalTo: topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),

            railView.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: 3),
            railView.widthAnchor.constraint(equalToConstant: SidebarAppKitCellMetrics.railWidth),
            railView.topAnchor.constraint(equalTo: backgroundView.topAnchor, constant: 5),
            railView.bottomAnchor.constraint(equalTo: backgroundView.bottomAnchor, constant: -5),

            contentStack.leadingAnchor.constraint(
                equalTo: backgroundView.leadingAnchor,
                constant: SidebarAppKitCellMetrics.innerHorizontalInset
            ),
            contentStack.trailingAnchor.constraint(
                equalTo: backgroundView.trailingAnchor,
                constant: -SidebarAppKitCellMetrics.innerHorizontalInset
            ),
            contentStack.topAnchor.constraint(
                equalTo: backgroundView.topAnchor,
                constant: SidebarAppKitCellMetrics.verticalInset
            ),
            contentStack.bottomAnchor.constraint(
                equalTo: backgroundView.bottomAnchor,
                constant: -SidebarAppKitCellMetrics.verticalInset
            ),

            topDropIndicator.leadingAnchor.constraint(equalTo: leadingAnchor),
            topDropIndicator.trailingAnchor.constraint(equalTo: trailingAnchor),
            topDropIndicator.topAnchor.constraint(equalTo: topAnchor),
            topDropIndicator.heightAnchor.constraint(equalToConstant: 2),
            bottomDropIndicator.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomDropIndicator.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomDropIndicator.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomDropIndicator.heightAnchor.constraint(equalToConstant: 2),
        ])
    }

    private func setUpRemoteRow() {
        remoteRow.translatesAutoresizingMaskIntoConstraints = false
        remoteRow.orientation = .horizontal
        remoteRow.alignment = .centerY
        remoteRow.distribution = .fill
        remoteRow.spacing = 6

        setUpTextLabel(remoteLabel, maximumLines: 1, monospaced: true)
        remoteLabel.lineBreakMode = .byTruncatingMiddle

        setUpTextLabel(remoteStatusLabel, maximumLines: 1)
        remoteStatusLabel.lineBreakMode = .byTruncatingTail
        remoteStatusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        remoteStatusLabel.setContentHuggingPriority(.required, for: .horizontal)

        remoteReconnectButton.translatesAutoresizingMaskIntoConstraints = false
        remoteReconnectButton.isBordered = false
        remoteReconnectButton.imagePosition = .imageLeading
        remoteReconnectButton.imageHugsTitle = true
        remoteReconnectButton.title = String(
            localized: "sidebar.remote.reconnect.button",
            defaultValue: "Reconnect"
        )
        remoteReconnectButton.image = NSImage(
            systemSymbolName: "arrow.clockwise",
            accessibilityDescription: nil
        )
        remoteReconnectButton.target = self
        remoteReconnectButton.action = #selector(reconnectRemote)
        remoteReconnectButton.setAccessibilityIdentifier("sidebarWorkspace.remoteReconnect")
        remoteReconnectButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        remoteReconnectButton.setContentHuggingPriority(.required, for: .horizontal)

        remoteRow.addArrangedSubview(remoteLabel)
        remoteRow.addArrangedSubview(remoteStatusLabel)
        remoteRow.addArrangedSubview(remoteReconnectButton)
    }

    private func setUpTitleRow() {
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.distribution = .fill
        titleRow.spacing = 6

        leadingSpinner.translatesAutoresizingMaskIntoConstraints = false
        trailingSpinner.translatesAutoresizingMaskIntoConstraints = false
        leadingSpinner.style = .macOSSpokes
        trailingSpinner.style = .macOSSpokes

        for imageView in [pinImageView, mediaImageView] {
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.imageScaling = .scaleProportionallyDown
            imageView.setAccessibilityElement(false)
        }

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.cell?.wraps = true
        titleLabel.cell?.usesSingleLineMode = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        renameField.translatesAutoresizingMaskIntoConstraints = false
        renameField.isBordered = false
        renameField.drawsBackground = false
        renameField.focusRingType = .none
        renameField.usesSingleLineMode = true
        renameField.cell?.usesSingleLineMode = true
        renameField.cell?.wraps = false
        renameField.maximumNumberOfLines = 1
        renameField.lineBreakMode = .byTruncatingTail
        renameField.placeholderString = String(
            localized: "commandPalette.rename.workspacePlaceholder",
            defaultValue: "Workspace name"
        )
        renameField.setAccessibilityLabel(String(
            localized: "sidebar.workspace.rename.field.accessibilityLabel",
            defaultValue: "Rename workspace"
        ))
        renameField.delegate = self
        renameField.isHidden = true
        renameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        renameField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
        shortcutLabel.alignment = .right
        shortcutLabel.maximumNumberOfLines = 1
        shortcutLabel.lineBreakMode = .byClipping
        shortcutLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        closeButton.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: GlobalFontMagnification.scaledSize(9),
            weight: .medium
        )
        closeButton.target = self
        closeButton.action = #selector(closeWorkspace)

        [
            leadingBadge,
            leadingSpinner,
            pinImageView,
            mediaImageView,
            titleLabel,
            renameField,
            shortcutLabel,
            trailingSpinner,
            trailingBadge,
            closeButton,
        ].forEach(titleRow.addArrangedSubview)

        NSLayoutConstraint.activate([
            leadingSpinner.widthAnchor.constraint(equalToConstant: SidebarAppKitCellMetrics.accessorySide),
            leadingSpinner.heightAnchor.constraint(equalToConstant: SidebarAppKitCellMetrics.accessorySide),
            trailingSpinner.widthAnchor.constraint(equalToConstant: SidebarAppKitCellMetrics.accessorySide),
            trailingSpinner.heightAnchor.constraint(equalToConstant: SidebarAppKitCellMetrics.accessorySide),
            pinImageView.widthAnchor.constraint(equalToConstant: 12),
            pinImageView.heightAnchor.constraint(equalToConstant: 14),
            mediaImageView.widthAnchor.constraint(equalToConstant: 13),
            mediaImageView.heightAnchor.constraint(equalToConstant: 14),
            closeButton.widthAnchor.constraint(equalToConstant: SidebarAppKitCellMetrics.accessorySide),
            closeButton.heightAnchor.constraint(equalToConstant: SidebarAppKitCellMetrics.accessorySide),
        ])
    }

    private func setUpTextLabel(
        _ label: NSTextField,
        maximumLines: Int,
        monospaced: Bool = false
    ) {
        label.translatesAutoresizingMaskIntoConstraints = false
        label.maximumNumberOfLines = maximumLines
        label.lineBreakMode = maximumLines == 1 ? .byTruncatingMiddle : .byTruncatingTail
        label.cell?.wraps = maximumLines > 1
        label.cell?.usesSingleLineMode = maximumLines == 1
        label.font = monospaced
            ? GlobalFontMagnification.monospacedSystemFont(ofSize: 10, weight: .regular)
            : GlobalFontMagnification.systemFont(ofSize: 10)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    private func setUpProgress() {
        progressStack.translatesAutoresizingMaskIntoConstraints = false
        progressStack.orientation = .vertical
        progressStack.alignment = .leading
        progressStack.distribution = .fill
        progressStack.spacing = 2

        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.style = .bar
        progressIndicator.controlSize = .small
        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 1

        setUpTextLabel(progressLabel, maximumLines: 1)
        progressStack.addArrangedSubview(progressIndicator)
        progressStack.addArrangedSubview(progressLabel)
        progressIndicator.widthAnchor.constraint(equalTo: progressStack.widthAnchor).isActive = true
        progressLabel.widthAnchor.constraint(equalTo: progressStack.widthAnchor).isActive = true
    }

    private func setUpChecklist() {
        checklistButton.translatesAutoresizingMaskIntoConstraints = false
        checklistButton.isBordered = false
        checklistButton.imagePosition = .imageLeading
        checklistButton.imageHugsTitle = true
        checklistButton.alignment = .left
        checklistButton.lineBreakMode = .byTruncatingTail
        checklistButton.target = self
        checklistButton.action = #selector(openChecklist)
        checklistButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        checklistButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        checklistButton.setAccessibilityIdentifier("SidebarChecklistSummaryLine")
    }

    private func setUpDropIndicator(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        view.layer?.cornerRadius = 1
        view.isHidden = true
    }

    private func setUpAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        titleLabel.setAccessibilityElement(false)
        renameField.setAccessibilityIdentifier("sidebarWorkspace.rename")
        descriptionLabel.setAccessibilityElement(false)
        subtitleLabel.setAccessibilityElement(false)
        remoteRow.setAccessibilityElement(true)
        remoteRow.setAccessibilityRole(.group)
        remoteLabel.setAccessibilityElement(false)
        remoteStatusLabel.setAccessibilityElement(false)
        remoteReconnectButton.setAccessibilityElement(true)
        remoteReconnectButton.setAccessibilityRole(.button)
        remoteReconnectButton.setAccessibilityLabel(remoteReconnectButton.title)
        progressLabel.setAccessibilityElement(false)
        checklistButton.setAccessibilityRole(.button)
        closeButton.setAccessibilityIdentifier("sidebarWorkspace.close")
    }

    private func configurePin(_ isPinned: Bool, scale: CGFloat) {
        pinImageView.isHidden = !isPinned
        guard isPinned else { return }
        pinImageView.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)
        pinImageView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: GlobalFontMagnification.scaledSize(9 * scale),
            weight: .semibold
        )
        pinImageView.toolTip = String(
            localized: "sidebar.pinnedWorkspaceProtected.tooltip",
            defaultValue: "Pinned workspace. Closing requires confirmation."
        )
    }

    private func configureMediaActivity(_ activity: BrowserMediaActivity, scale: CGFloat) {
        let symbol: String?
        let color: NSColor
        if activity.isUsingCamera {
            symbol = "video.fill"
            color = .systemGreen
        } else if activity.isUsingMicrophone {
            symbol = "mic.fill"
            color = .systemOrange
        } else if activity.isPlayingAudio {
            symbol = "speaker.wave.2.fill"
            color = .secondaryLabelColor
        } else {
            symbol = nil
            color = .secondaryLabelColor
        }
        mediaImageView.isHidden = symbol == nil
        mediaImageView.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        mediaImageView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: GlobalFontMagnification.scaledSize(9 * scale),
            weight: .semibold
        )
        mediaImageView.contentTintColor = color
    }

    private func configureSubtitle(snapshot: SidebarWorkspaceRowSnapshot, scale: CGFloat) {
        let workspace = snapshot.workspace
        let description = snapshot.settings.showsWorkspaceDescription
            ? SidebarAppKitCellText.bounded(
                workspace.customDescription,
                maximumCharacters: 2_048,
                maximumLines: 3
            )
            : nil
        descriptionLabel.stringValue = description ?? ""
        descriptionLabel.isHidden = description == nil
        descriptionLabel.maximumNumberOfLines = 3
        descriptionLabel.font = GlobalFontMagnification.systemFont(ofSize: 10 * scale)

        let conversationSubtitle = !snapshot.settings.hidesAllDetails && snapshot.settings.iMessageModeEnabled
            ? workspace.latestConversationMessage
            : nil
        let subtitle = snapshot.latestNotificationText ?? conversationSubtitle
        let lineLimit = snapshot.latestNotificationText == nil
            ? 2
            : max(1, snapshot.settings.notificationMessageLineLimit)
        let bounded = SidebarAppKitCellText.bounded(
            subtitle,
            maximumCharacters: 4_096,
            maximumLines: lineLimit
        )
        subtitleLabel.stringValue = bounded ?? ""
        subtitleLabel.isHidden = bounded == nil
        subtitleLabel.maximumNumberOfLines = lineLimit
        subtitleLabel.font = GlobalFontMagnification.systemFont(ofSize: 10 * scale)
    }

    private func configureRemoteDetail(snapshot: SidebarWorkspaceRowSnapshot, scale: CGFloat) {
        let workspace = snapshot.workspace
        guard !snapshot.settings.hidesAllDetails,
              snapshot.settings.showsSSH,
              let target = SidebarAppKitCellText.bounded(
                workspace.remoteWorkspaceSidebarText,
                maximumCharacters: 1_024,
                maximumLines: 1
              ) else {
            copyableRemoteError = nil
            remoteRow.toolTip = nil
            remoteRow.isHidden = true
            remoteRow.setAccessibilityLabel(nil)
            remoteRow.setAccessibilityValue(nil)
            remoteRow.setAccessibilityHelp(nil)
            remoteLabel.stringValue = ""
            remoteLabel.toolTip = nil
            remoteStatusLabel.stringValue = ""
            remoteStatusLabel.toolTip = nil
            remoteReconnectButton.toolTip = nil
            remoteReconnectButton.isHidden = true
            remoteReconnectButton.setAccessibilityHelp(nil)
            return
        }
        let status = SidebarAppKitCellText.bounded(
            workspace.remoteConnectionStatusText,
            maximumCharacters: 256,
            maximumLines: 1
        )
        let help = workspace.remoteStateHelpText

        remoteRow.isHidden = false
        remoteRow.toolTip = help
        remoteRow.setAccessibilityLabel(target)
        remoteRow.setAccessibilityValue(status)
        remoteRow.setAccessibilityHelp(help)

        remoteLabel.stringValue = target
        remoteLabel.font = GlobalFontMagnification.monospacedSystemFont(
            ofSize: 10 * scale,
            weight: .regular
        )
        remoteLabel.toolTip = help
        remoteStatusLabel.stringValue = status ?? ""
        remoteStatusLabel.font = GlobalFontMagnification.systemFont(
            ofSize: 9 * scale,
            weight: .medium
        )
        remoteStatusLabel.toolTip = help
        remoteStatusLabel.isHidden = status == nil

        let reconnectHelp = String(
            format: String(
                localized: "sidebar.remote.reconnect.help",
                defaultValue: "Reconnect to %@"
            ),
            locale: .current,
            target
        )
        remoteReconnectButton.font = GlobalFontMagnification.systemFont(
            ofSize: 9 * scale,
            weight: .semibold
        )
        remoteReconnectButton.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: GlobalFontMagnification.scaledSize(8 * scale),
            weight: .semibold
        )
        remoteReconnectButton.toolTip = reconnectHelp
        remoteReconnectButton.setAccessibilityHelp(reconnectHelp)
        remoteReconnectButton.isHidden = !workspace.showsRemoteReconnectAffordance

        copyableRemoteError = workspace.copyableSidebarSSHError
    }

    private func configureAuxiliaryDetails(snapshot: SidebarWorkspaceRowSnapshot, scale: CGFloat) {
        let selection = resolvedSelectionColor(snapshot: snapshot)
        let primary = snapshot.isActive
            ? sidebarSelectedWorkspaceForegroundNSColor(on: selection, opacity: 1)
            : NSColor.labelColor
        let secondary = snapshot.isActive
            ? sidebarSelectedWorkspaceForegroundNSColor(on: selection, opacity: 0.75)
            : NSColor.secondaryLabelColor
        detailsView.configure(
            snapshot: snapshot,
            fontScale: scale,
            primaryColor: primary,
            secondaryColor: secondary,
            actions: SidebarAppKitWorkspaceDetailsView.Actions(
                onActivate: actions.onActivate,
                onOpenMetadataURL: actions.onOpenMetadataURL,
                onOpenPullRequest: actions.onOpenPullRequest,
                onOpenPort: actions.onOpenPort
            )
        )
    }

    private func configureProgress(snapshot: SidebarWorkspaceRowSnapshot, scale: CGFloat) {
        guard snapshot.settings.visibleAuxiliaryDetails.showsProgress,
              let progress = snapshot.workspace.progress else {
            progressStack.isHidden = true
            progressIndicator.doubleValue = 0
            progressLabel.stringValue = ""
            progressLabel.isHidden = true
            return
        }
        progressStack.isHidden = false
        progressIndicator.doubleValue = min(1, max(0, progress.value))
        progressLabel.font = GlobalFontMagnification.systemFont(ofSize: 9 * scale)
        let label = SidebarAppKitCellText.bounded(
            progress.label,
            maximumCharacters: 1_024,
            maximumLines: 1
        )
        progressLabel.stringValue = label ?? ""
        progressLabel.isHidden = label == nil
    }

    /// Keeps the collapsed-row checklist projection constant-size. Detailed
    /// item rendering is resolved only after the native inline expansion or
    /// popover is explicitly presented.
    private func configureChecklist(snapshot: SidebarWorkspaceRowSnapshot, scale: CGFloat) {
        let workspace = snapshot.workspace
        guard workspace.checklistTotalCount > 0 else {
            checklistButton.title = ""
            checklistButton.attributedTitle = NSAttributedString(string: "")
            checklistButton.image = nil
            checklistButton.toolTip = nil
            checklistButton.isHidden = true
            return
        }

        let progress = "\(workspace.checklistCompletedCount)/\(workspace.checklistTotalCount)"
        let firstUnchecked = SidebarAppKitCellText.bounded(
            workspace.checklistFirstUncheckedText,
            maximumCharacters: 1_024,
            maximumLines: 1
        )
        checklistButton.title = [progress, firstUnchecked]
            .compactMap { $0 }
            .joined(separator: "  ·  ")
        checklistButton.font = GlobalFontMagnification.monospacedDigitSystemFont(
            ofSize: 10 * scale,
            weight: .semibold
        )
        checklistButton.image = NSImage(
            systemSymbolName: workspace.checklistCompletedCount == workspace.checklistTotalCount
                ? "checkmark.circle.fill"
                : "checklist",
            accessibilityDescription: nil
        )
        checklistButton.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: GlobalFontMagnification.scaledSize(8 * scale),
            weight: .regular
        )
        switch actions.checklistStyle {
        case .popover:
            checklistButton.toolTip = String(
                localized: "sidebar.checklist.popoverTooltip",
                defaultValue: "Show checklist"
            )
        case .inline:
            checklistButton.toolTip = snapshot.isChecklistExpanded
                ? String(
                    localized: "sidebar.checklist.collapseTooltip",
                    defaultValue: "Collapse checklist"
                )
                : String(
                    localized: "sidebar.checklist.expandTooltip",
                    defaultValue: "Expand checklist"
                )
        }
        checklistButton.setAccessibilityLabel(checklistButton.title)
        checklistButton.setAccessibilityHelp(checklistButton.toolTip)
        checklistButton.isHidden = false
    }

    private func configureInlineChecklist(snapshot: SidebarWorkspaceRowSnapshot) {
        guard snapshot.isChecklistExpanded,
              actions.checklistStyle == .inline,
              let workspace = actions.resolveChecklistWorkspace() else {
            inlineChecklistView?.stopObserving()
            inlineChecklistView?.isHidden = true
            return
        }

        let checklistView: SidebarAppKitChecklistView
        if let inlineChecklistView {
            checklistView = inlineChecklistView
        } else {
            checklistView = SidebarAppKitChecklistView(frame: .zero)
            inlineChecklistView = checklistView
            contentStack.addArrangedSubview(checklistView)
            checklistView.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }
        checklistView.isHidden = false
        checklistView.configure(
            workspace: workspace,
            mode: .inline,
            onPreferredHeightChange: { [weak self] in
                self?.actions.onChecklistHeightChanged()
            },
            onRequestClose: { [weak self] in
                guard let self else { return }
                self.actions.onOpenChecklist(self.checklistButton)
            }
        )
    }

    var checklistPresentationAnchor: NSView {
        checklistButton.isHidden ? self : checklistButton
    }

    @discardableResult
    func focusInlineChecklistAddField() -> Bool {
        guard let inlineChecklistView, !inlineChecklistView.isHidden else { return false }
        inlineChecklistView.focusAddField()
        return true
    }

    private func configureStatusAccessories(snapshot: SidebarWorkspaceRowSnapshot, scale: CGFloat) {
        let showsSpinner = snapshot.showsAgentActivity && snapshot.workspace.activeCodingAgentCount > 0
        let leadingSpinnerVisible = showsSpinner && snapshot.settings.loadingSpinnerPosition == .leading
        let trailingSpinnerVisible = showsSpinner && snapshot.settings.loadingSpinnerPosition == .trailing
        let leadingBadgeVisible = snapshot.unreadCount > 0
            && snapshot.settings.notificationBadgePosition == .leading
            && !leadingSpinnerVisible
        let trailingBadgeVisible = snapshot.unreadCount > 0
            && snapshot.settings.notificationBadgePosition == .trailing
            && !trailingSpinnerVisible

        let selection = resolvedSelectionColor(snapshot: snapshot)
        let primary = snapshot.isActive
            ? sidebarSelectedWorkspaceForegroundNSColor(on: selection, opacity: 1)
            : NSColor.white
        let customBadgeColor = snapshot.settings.notificationBadgeColorHex.flatMap(NSColor.init(hex:))
        badgeFillColor = customBadgeColor
            ?? (snapshot.isActive
                ? sidebarSelectedWorkspaceForegroundNSColor(on: selection, opacity: 0.25)
                : cmuxAccentNSColor(for: effectiveAppearance))
        let badgeText = snapshot.isActive
            ? sidebarSelectedWorkspaceForegroundNSColor(on: selection, opacity: 1)
            : primary
        let badgeFont = GlobalFontMagnification.systemFont(
            ofSize: 9 * scale,
            weight: .semibold
        )
        let badgeHeight = GlobalFontMagnification.scaledSize(
            SidebarAppKitCellMetrics.accessorySide * scale
        )

        if leadingBadgeVisible {
            leadingBadge.configure(
                count: snapshot.unreadCount,
                fillColor: badgeFillColor,
                textColor: badgeText,
                font: badgeFont,
                height: badgeHeight
            )
        } else {
            leadingBadge.resetForReuse()
        }
        if trailingBadgeVisible {
            trailingBadge.configure(
                count: snapshot.unreadCount,
                fillColor: badgeFillColor,
                textColor: badgeText,
                font: badgeFont,
                height: badgeHeight
            )
        } else {
            trailingBadge.resetForReuse()
        }

        let spinnerColor = snapshot.isActive
            ? sidebarSelectedWorkspaceForegroundNSColor(on: selection, opacity: 0.55)
            : .secondaryLabelColor
        let spinnerTooltip = SidebarWorkspaceLoadingTooltip.text(
            count: snapshot.workspace.activeCodingAgentCount
        )
        leadingSpinner.isHidden = !leadingSpinnerVisible
        leadingSpinner.color = spinnerColor
        leadingSpinner.toolTip = leadingSpinnerVisible ? spinnerTooltip : nil
        trailingSpinner.isHidden = !trailingSpinnerVisible
        trailingSpinner.color = spinnerColor
        trailingSpinner.toolTip = trailingSpinnerVisible ? spinnerTooltip : nil

        let shortcutVisible = (snapshot.showsModifierShortcutHints || snapshot.settings.alwaysShowShortcutHints)
            && snapshot.workspaceShortcutDigit != nil
        if shortcutVisible, let digit = snapshot.workspaceShortcutDigit {
            shortcutLabel.stringValue = "\(snapshot.workspaceShortcutModifierSymbol)\(digit)"
            shortcutLabel.font = GlobalFontMagnification.monospacedSystemFont(
                ofSize: 10 * scale,
                weight: .semibold
            )
            shortcutLabel.isHidden = false
        } else {
            shortcutLabel.stringValue = ""
            shortcutLabel.isHidden = true
        }
    }

    private func configureColors(snapshot: SidebarWorkspaceRowSnapshot) {
        let selection = resolvedSelectionColor(snapshot: snapshot)
        selectedBackgroundColor = selection
        let accent = cmuxAccentNSColor(for: effectiveAppearance)
        let custom = snapshot.workspace.customColorHex.flatMap(NSColor.init(hex:))

        let background: NSColor?
        switch snapshot.settings.activeTabIndicatorStyle {
        case .leftRail:
            if snapshot.isActive {
                background = selection
            } else if snapshot.isMultiSelected {
                background = accent.withAlphaComponent(0.25)
            } else {
                background = nil
            }
        case .solidFill:
            if snapshot.isActive {
                background = selection
            } else if let custom {
                background = custom.withAlphaComponent(snapshot.isMultiSelected ? 0.35 : 0.7)
            } else if snapshot.isMultiSelected {
                background = accent.withAlphaComponent(0.25)
            } else {
                background = nil
            }
        }

        let primary = snapshot.isActive
            ? sidebarSelectedWorkspaceForegroundNSColor(on: selection, opacity: 1)
            : .labelColor
        let secondary = snapshot.isActive
            ? sidebarSelectedWorkspaceForegroundNSColor(on: selection, opacity: 0.75)
            : .secondaryLabelColor
        let tertiary = snapshot.isActive
            ? sidebarSelectedWorkspaceForegroundNSColor(on: selection, opacity: 0.6)
            : .tertiaryLabelColor

        titleLabel.textColor = primary
        renameField.textColor = primary
        (renameField.currentEditor() as? NSTextView)?.insertionPointColor = primary
        descriptionLabel.textColor = secondary
        subtitleLabel.textColor = secondary
        remoteLabel.textColor = secondary
        remoteStatusLabel.textColor = tertiary
        remoteReconnectButton.contentTintColor = secondary
        progressLabel.textColor = tertiary
        checklistButton.contentTintColor = secondary
        checklistButton.attributedTitle = NSAttributedString(
            string: checklistButton.title,
            attributes: [
                .foregroundColor: secondary,
                .font: checklistButton.font ?? GlobalFontMagnification.systemFont(ofSize: 10),
            ]
        )
        pinImageView.contentTintColor = secondary
        shortcutLabel.textColor = secondary
        closeButton.contentTintColor = secondary

        effectiveAppearance.performAsCurrentDrawingAppearance {
            backgroundView.layer?.backgroundColor = background?.usingColorSpace(.deviceRGB)?.cgColor
            if snapshot.isActive, snapshot.settings.activeTabIndicatorStyle == .solidFill {
                backgroundView.layer?.borderWidth = 1.5
                backgroundView.layer?.borderColor = primary.withAlphaComponent(0.5)
                    .usingColorSpace(.deviceRGB)?.cgColor
            } else if snapshot.isBonsplitWorkspaceDropActive {
                backgroundView.layer?.borderWidth = 1.5
                backgroundView.layer?.borderColor = accent.usingColorSpace(.deviceRGB)?.cgColor
            } else {
                backgroundView.layer?.borderWidth = 0
                backgroundView.layer?.borderColor = nil
            }
            railView.layer?.backgroundColor = custom?.withAlphaComponent(0.95)
                .usingColorSpace(.deviceRGB)?.cgColor
        }
        railView.isHidden = snapshot.settings.activeTabIndicatorStyle != .leftRail || custom == nil
    }

    private func configureAccessibility(snapshot: SidebarWorkspaceRowSnapshot) {
        let title = String(
            localized: "accessibility.workspacePosition",
            defaultValue: "\(snapshot.workspace.title), workspace \(snapshot.index + 1) of \(snapshot.workspaceCount)"
        )
        setAccessibilityIdentifier("sidebarWorkspace.\(snapshot.workspaceId.uuidString)")
        setAccessibilityLabel(title)
        setAccessibilityHint(String(
            localized: "sidebar.workspace.accessibilityHint",
            defaultValue: "Activate to focus this workspace. Drag to reorder, or use Move Up and Move Down actions."
        ))
        setAccessibilitySelected(snapshot.isActive || snapshot.isMultiSelected)
        if snapshot.unreadCount > 0 {
            setAccessibilityValue(String.localizedStringWithFormat(
                String(localized: "workspaceGroup.unread.a11y", defaultValue: "%lld unread"),
                Int64(snapshot.unreadCount)
            ))
        } else {
            setAccessibilityValue(nil)
        }

        let closeLabel = String(
            localized: "sidebar.closeWorkspace.tooltip",
            defaultValue: "Close Workspace"
        )
        closeButton.setAccessibilityLabel(closeLabel)
        closeButton.toolTip = snapshot.workspace.isPinned
            ? String(
                localized: "sidebar.pinnedWorkspaceProtected.tooltip",
                defaultValue: "Pinned workspace. Closing requires confirmation."
            )
            : closeLabel
        var customActions = [moveUpAccessibilityAction, moveDownAccessibilityAction]
        if copyableRemoteError != nil {
            customActions.append(copyRemoteErrorAccessibilityAction)
        }
        setAccessibilityCustomActions(customActions)
    }

    private func refreshFontMagnification() {
        guard let snapshot else { return }
        let scale = max(0.5, snapshot.settings.sidebarFontScale)
        closeButton.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: GlobalFontMagnification.scaledSize(9 * scale),
            weight: .medium
        )
        titleLabel.font = GlobalFontMagnification.systemFont(
            ofSize: 12.5 * scale,
            weight: .semibold
        )
        renameField.font = titleLabel.font
        configurePin(snapshot.workspace.isPinned, scale: scale)
        configureMediaActivity(snapshot.workspace.mediaActivity, scale: scale)
        configureSubtitle(snapshot: snapshot, scale: scale)
        configureRemoteDetail(snapshot: snapshot, scale: scale)
        configureAuxiliaryDetails(snapshot: snapshot, scale: scale)
        configureProgress(snapshot: snapshot, scale: scale)
        configureChecklist(snapshot: snapshot, scale: scale)
        configureStatusAccessories(snapshot: snapshot, scale: scale)
        configureColors(snapshot: snapshot)
        configureAccessibility(snapshot: snapshot)
        needsLayout = true
        actions.onChecklistHeightChanged()
    }

    private func resolvedSelectionColor(snapshot: SidebarWorkspaceRowSnapshot) -> NSColor {
        snapshot.settings.selectionColorHex.flatMap(NSColor.init(hex:))
            ?? cmuxAccentNSColor(for: effectiveAppearance)
    }

    private func updateTrailingAccessoryVisibility() {
        guard let snapshot else {
            closeButton.isHidden = true
            return
        }
        let hasShortcut = !shortcutLabel.isHidden
        let showsClose = isPointerInside && snapshot.canCloseWorkspace && !hasShortcut
        closeButton.isHidden = !showsClose
        if snapshot.settings.loadingSpinnerPosition == .trailing {
            trailingSpinner.isHidden = showsClose
                || !snapshot.showsAgentActivity
                || snapshot.workspace.activeCodingAgentCount == 0
        }
        if snapshot.settings.notificationBadgePosition == .trailing {
            trailingBadge.isHidden = showsClose
                || snapshot.unreadCount == 0
                || (!trailingSpinner.isHidden && snapshot.workspace.activeCodingAgentCount > 0)
        }
        closeButton.setAccessibilityElement(showsClose)
    }

    private func updateDropIndicatorColors() {
        let color = cmuxAccentNSColor(for: effectiveAppearance)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            topDropIndicator.layer?.backgroundColor = color.usingColorSpace(.deviceRGB)?.cgColor
            bottomDropIndicator.layer?.backgroundColor = color.usingColorSpace(.deviceRGB)?.cgColor
        }
    }

    private var enclosingTableView: NSTableView? {
        var ancestor = superview
        while let view = ancestor {
            if let tableView = view as? NSTableView {
                return tableView
            }
            ancestor = view.superview
        }
        return nil
    }

    private func belongsToInteractiveSubview(_ view: NSView, ancestor: NSView) -> Bool {
        view === ancestor || view.isDescendant(of: ancestor)
    }

    private func beginInlineRename() {
        guard renameSession == nil, let snapshot else { return }
        renameSession = RenameSession(
            workspaceID: snapshot.workspaceId,
            baselineTitle: snapshot.workspace.title,
            baselineHadUserCustomTitle: snapshot.hasUserCustomTitle
        )
        renameHasMovedCaretToStart = false
        renameField.stringValue = snapshot.workspace.title
        titleLabel.isHidden = true
        renameField.isHidden = false
        needsLayout = true
        layoutSubtreeIfNeeded()

        guard window?.makeFirstResponder(renameField) == true else {
            discardInlineRename(resignFirstResponder: false)
            return
        }
        renameField.currentEditor()?.selectAll(nil)
        (renameField.currentEditor() as? NSTextView)?.insertionPointColor = renameField.textColor
    }

    private func commitInlineRename(_ draft: String, resignFirstResponder: Bool) {
        guard let renameSession else { return }
        let title = SidebarInlineRenameCommit().titleToCommit(
            draft: draft,
            baseline: renameSession.baselineTitle,
            baselineHadUserCustomTitle: renameSession.baselineHadUserCustomTitle
        )
        finishInlineRename(resignFirstResponder: resignFirstResponder)
        if let title {
            actions.onCommitRename(title)
        }
    }

    private func discardInlineRename(resignFirstResponder: Bool) {
        guard renameSession != nil else { return }
        finishInlineRename(resignFirstResponder: resignFirstResponder)
    }

    private func finishInlineRename(resignFirstResponder: Bool) {
        renameSession = nil
        renameHasMovedCaretToStart = false
        if resignFirstResponder {
            if let enclosingTableView {
                window?.makeFirstResponder(enclosingTableView)
            } else {
                window?.makeFirstResponder(nil)
            }
        }
        renameField.stringValue = ""
        renameField.isHidden = true
        titleLabel.isHidden = false
        needsLayout = true
    }

    @objc private func closeWorkspace() {
        actions.onClose()
    }

    @objc private func openChecklist() {
        actions.onOpenChecklist(checklistButton)
    }

    @objc private func reconnectRemote() {
        guard snapshot?.workspace.showsRemoteReconnectAffordance == true else { return }
        actions.onReconnectRemote()
    }

    @objc private func copyRemoteErrorForAccessibility() -> Bool {
        guard let copyableRemoteError else { return false }
        actions.onCopyRemoteError(copyableRemoteError)
        return true
    }

    @objc private func moveUpForAccessibility() -> Bool {
        actions.onMoveUp()
        return true
    }

    @objc private func moveDownForAccessibility() -> Bool {
        actions.onMoveDown()
        return true
    }
}
