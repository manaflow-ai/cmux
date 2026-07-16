import AppKit
import CmuxFoundation

/// Resolves its menu only when AppKit receives a context-click.
@MainActor
private final class SidebarAppKitDeferredMenuButton: NSButton {
    var menuProvider: ((NSEvent) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?(event) ?? super.menu(for: event)
    }
}

/// Reusable native cell for one immutable workspace-group header projection.
@MainActor
final class SidebarAppKitGroupCellView: NSTableCellView {
    struct Actions {
        let onActivate: () -> Void
        let onToggleCollapsed: () -> Void
        let onAddWorkspace: () -> Void
        let onContextMenu: (NSEvent) -> NSMenu?

        init(
            onActivate: @escaping () -> Void,
            onToggleCollapsed: @escaping () -> Void,
            onAddWorkspace: @escaping () -> Void,
            onContextMenu: @escaping (NSEvent) -> NSMenu? = { _ in nil }
        ) {
            self.onActivate = onActivate
            self.onToggleCollapsed = onToggleCollapsed
            self.onAddWorkspace = onAddWorkspace
            self.onContextMenu = onContextMenu
        }

        static let none = Self(
            onActivate: {},
            onToggleCollapsed: {},
            onAddWorkspace: {}
        )
    }

    private let backgroundView = NSView()
    private let rowStack = NSStackView()
    private let pinImageView = NSImageView()
    private let disclosureButton = NSButton()
    private let groupImageView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let unreadBadge = SidebarAppKitBadgeView()
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let addButton = SidebarAppKitDeferredMenuButton()
    private let topDropIndicator = NSView()
    private let bottomDropIndicator = NSView()

    private var snapshot: SidebarWorkspaceGroupRowSnapshot?
    private var actions = Actions.none
    private var isPointerInside = false
    private var pointerTrackingArea: NSTrackingArea?
    private var fontMagnificationObserver: GlobalFontMagnificationChangeObserver?

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
    func configure(snapshot: SidebarWorkspaceGroupRowSnapshot, actions: Actions) {
        self.snapshot = snapshot
        self.actions = actions

        let scale = max(0.5, snapshot.fontScale)
        nameLabel.stringValue = SidebarAppKitCellText.bounded(
            snapshot.name,
            maximumCharacters: 2_048,
            maximumLines: 1
        ) ?? snapshot.name
        nameLabel.font = GlobalFontMagnification.systemFont(
            ofSize: 11 * scale,
            weight: .semibold
        )
        nameLabel.toolTip = snapshot.name

        configureDisclosure(snapshot: snapshot, scale: scale)
        configurePin(snapshot: snapshot, scale: scale)
        configureGroupIcon(snapshot: snapshot, scale: scale)
        configureUnread(snapshot: snapshot, scale: scale)
        configureShortcut(snapshot: snapshot, scale: scale)
        configureColors(snapshot: snapshot)
        configureAccessibility(snapshot: snapshot)

        backgroundView.alphaValue = snapshot.isBeingDragged ? 0.6 : 1
        topDropIndicator.isHidden = !snapshot.topDropIndicatorVisible
        bottomDropIndicator.isHidden = !snapshot.bottomDropIndicatorVisible
        isPointerInside = snapshot.isPointerHovering
        updateAddButtonVisibility()
        updateDropIndicatorColors()
        needsLayout = true
    }

    /// Clears model-derived content and callbacks before a cell enters reuse.
    func resetForReuse() {
        snapshot = nil
        actions = .none
        isPointerInside = false

        nameLabel.stringValue = ""
        nameLabel.toolTip = nil
        pinImageView.isHidden = true
        pinImageView.toolTip = nil
        disclosureButton.image = nil
        disclosureButton.toolTip = nil
        groupImageView.image = nil
        groupImageView.isHidden = true
        unreadBadge.resetForReuse()
        shortcutLabel.stringValue = ""
        shortcutLabel.isHidden = true
        addButton.isHidden = true
        addButton.setAccessibilityElement(false)

        backgroundView.alphaValue = 1
        backgroundView.layer?.backgroundColor = nil
        backgroundView.layer?.borderColor = nil
        backgroundView.layer?.borderWidth = 0
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
        nameLabel.preferredMaxLayoutWidth = max(1, width - horizontalInsets)
        layoutSubtreeIfNeeded()
        return ceil(max(
            SidebarAppKitCellMetrics.minimumGroupHeight,
            rowStack.fittingSize.height + 10
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
        updateAddButtonVisibility()
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        updateAddButtonVisibility()
    }

    /// Buttons keep their own events. Ordinary group-row hits go to the table,
    /// which owns selection, modifier handling, menus, and native dragging.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hitView = super.hitTest(point) else { return nil }
        if belongsToInteractiveSubview(hitView, ancestor: disclosureButton)
            || belongsToInteractiveSubview(hitView, ancestor: addButton) {
            return hitView
        }
        return enclosingTableView ?? hitView
    }

    override func accessibilityPerformPress() -> Bool {
        actions.onActivate()
        return true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard let snapshot else { return }
        configureColors(snapshot: snapshot)
        updateDropIndicatorColors()
    }

    private func setUpHierarchy() {
        wantsLayer = true
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = SidebarAppKitCellMetrics.groupCornerRadius
        addSubview(backgroundView)

        rowStack.translatesAutoresizingMaskIntoConstraints = false
        rowStack.orientation = .horizontal
        rowStack.alignment = .centerY
        rowStack.distribution = .fill
        rowStack.spacing = 4
        backgroundView.addSubview(rowStack)

        setUpImageView(pinImageView)
        setUpButton(disclosureButton, action: #selector(toggleCollapsed))
        setUpImageView(groupImageView)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.maximumNumberOfLines = 1
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
        shortcutLabel.maximumNumberOfLines = 1
        shortcutLabel.lineBreakMode = .byClipping
        shortcutLabel.alignment = .right
        shortcutLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        setUpButton(addButton, action: #selector(addWorkspace))
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        addButton.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: GlobalFontMagnification.scaledSize(11),
            weight: .medium
        )
        addButton.menuProvider = { [weak self] event in
            self?.actions.onContextMenu(event)
        }

        [
            pinImageView,
            disclosureButton,
            groupImageView,
            nameLabel,
            unreadBadge,
            shortcutLabel,
            addButton,
        ].forEach(rowStack.addArrangedSubview)

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

            rowStack.leadingAnchor.constraint(
                equalTo: backgroundView.leadingAnchor,
                constant: SidebarAppKitCellMetrics.innerHorizontalInset
            ),
            rowStack.trailingAnchor.constraint(
                equalTo: backgroundView.trailingAnchor,
                constant: -SidebarAppKitCellMetrics.innerHorizontalInset
            ),
            rowStack.topAnchor.constraint(equalTo: backgroundView.topAnchor, constant: 5),
            rowStack.bottomAnchor.constraint(equalTo: backgroundView.bottomAnchor, constant: -5),

            pinImageView.widthAnchor.constraint(equalToConstant: SidebarAppKitCellMetrics.groupAccessorySide),
            pinImageView.heightAnchor.constraint(equalToConstant: SidebarAppKitCellMetrics.groupAccessorySide),
            disclosureButton.widthAnchor.constraint(equalToConstant: SidebarAppKitCellMetrics.groupAccessorySide),
            disclosureButton.heightAnchor.constraint(equalToConstant: SidebarAppKitCellMetrics.groupAccessorySide),
            groupImageView.widthAnchor.constraint(equalToConstant: SidebarAppKitCellMetrics.groupAccessorySide),
            groupImageView.heightAnchor.constraint(equalToConstant: SidebarAppKitCellMetrics.groupAccessorySide),
            addButton.widthAnchor.constraint(equalToConstant: SidebarAppKitCellMetrics.accessorySide),
            addButton.heightAnchor.constraint(equalToConstant: SidebarAppKitCellMetrics.accessorySide),

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

    private func belongsToInteractiveSubview(_ view: NSView, ancestor: NSView) -> Bool {
        var candidate: NSView? = view
        while let current = candidate {
            if current === ancestor { return true }
            if current === self { return false }
            candidate = current.superview
        }
        return false
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

    private func setUpImageView(_ imageView: NSImageView) {
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyDown
        imageView.setAccessibilityElement(false)
    }

    private func setUpButton(_ button: NSButton, action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.target = self
        button.action = action
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
        nameLabel.setAccessibilityElement(false)
        pinImageView.setAccessibilityElement(false)
        groupImageView.setAccessibilityElement(false)
        disclosureButton.setAccessibilityIdentifier("sidebarWorkspaceGroup.disclosure")
        addButton.setAccessibilityIdentifier("sidebarWorkspaceGroup.addWorkspace")
    }

    private func configureDisclosure(snapshot: SidebarWorkspaceGroupRowSnapshot, scale: CGFloat) {
        let symbol = snapshot.isCollapsed ? "chevron.right" : "chevron.down"
        disclosureButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        disclosureButton.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: GlobalFontMagnification.scaledSize(9 * scale),
            weight: .semibold
        )
        let label = snapshot.isCollapsed
            ? String(localized: "workspaceGroup.expand.a11y", defaultValue: "Expand group")
            : String(localized: "workspaceGroup.collapse.a11y", defaultValue: "Collapse group")
        disclosureButton.setAccessibilityLabel(label)
        disclosureButton.toolTip = label
    }

    private func configurePin(snapshot: SidebarWorkspaceGroupRowSnapshot, scale: CGFloat) {
        pinImageView.isHidden = !snapshot.isPinned
        guard snapshot.isPinned else { return }
        pinImageView.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)
        pinImageView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: GlobalFontMagnification.scaledSize(9 * scale),
            weight: .semibold
        )
        pinImageView.toolTip = String(
            localized: "workspaceGroup.pinned.tooltip",
            defaultValue: "Pinned group"
        )
    }

    private func configureGroupIcon(snapshot: SidebarWorkspaceGroupRowSnapshot, scale: CGFloat) {
        let configured = NSImage(systemSymbolName: snapshot.iconSymbol, accessibilityDescription: nil)
        groupImageView.image = configured
            ?? NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)
        groupImageView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: GlobalFontMagnification.scaledSize(11 * scale),
            weight: .semibold
        )
        groupImageView.isHidden = false
    }

    private func configureUnread(snapshot: SidebarWorkspaceGroupRowSnapshot, scale: CGFloat) {
        guard snapshot.anchorUnreadCount > 0 else {
            unreadBadge.resetForReuse()
            return
        }
        unreadBadge.configure(
            count: snapshot.anchorUnreadCount,
            fillColor: cmuxAccentNSColor(for: effectiveAppearance),
            textColor: .white,
            font: GlobalFontMagnification.systemFont(
                ofSize: 10 * scale,
                weight: .semibold
            ),
            height: GlobalFontMagnification.scaledSize(
                SidebarAppKitCellMetrics.accessorySide * scale
            )
        )
    }

    private func configureShortcut(snapshot: SidebarWorkspaceGroupRowSnapshot, scale: CGFloat) {
        guard snapshot.showsShortcutHint,
              let modifier = snapshot.shortcutModifierSymbol,
              let digit = snapshot.shortcutDigit else {
            shortcutLabel.stringValue = ""
            shortcutLabel.isHidden = true
            return
        }
        shortcutLabel.stringValue = "\(modifier)\(digit)"
        shortcutLabel.font = GlobalFontMagnification.monospacedSystemFont(
            ofSize: 10 * scale,
            weight: .semibold
        )
        shortcutLabel.isHidden = false
    }

    private func refreshFontMagnification() {
        guard let snapshot else { return }
        let scale = max(0.5, snapshot.fontScale)
        nameLabel.font = GlobalFontMagnification.systemFont(
            ofSize: 11 * scale,
            weight: .semibold
        )
        configureDisclosure(snapshot: snapshot, scale: scale)
        configurePin(snapshot: snapshot, scale: scale)
        configureGroupIcon(snapshot: snapshot, scale: scale)
        configureUnread(snapshot: snapshot, scale: scale)
        configureShortcut(snapshot: snapshot, scale: scale)
        addButton.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: GlobalFontMagnification.scaledSize(11),
            weight: .medium
        )
        needsLayout = true
        if let tableView = enclosingTableView {
            let row = tableView.row(for: self)
            if row >= 0 {
                tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
            }
        }
    }

    private func configureColors(snapshot: SidebarWorkspaceGroupRowSnapshot) {
        let accent = cmuxAccentNSColor(for: effectiveAppearance)
        let tint = snapshot.tintHex.flatMap(NSColor.init(hex:)) ?? .secondaryLabelColor
        let activeBackground = snapshot.isAnchorActive ? accent.withAlphaComponent(0.16) : nil

        nameLabel.textColor = snapshot.isAnchorActive ? .labelColor : .labelColor.withAlphaComponent(0.9)
        disclosureButton.contentTintColor = .secondaryLabelColor
        pinImageView.contentTintColor = .secondaryLabelColor
        groupImageView.contentTintColor = tint
        shortcutLabel.textColor = .secondaryLabelColor
        addButton.contentTintColor = .secondaryLabelColor

        effectiveAppearance.performAsCurrentDrawingAppearance {
            backgroundView.layer?.backgroundColor = activeBackground?
                .usingColorSpace(.deviceRGB)?.cgColor
            backgroundView.layer?.borderWidth = snapshot.isAnchorActive ? 1 : 0
            backgroundView.layer?.borderColor = snapshot.isAnchorActive
                ? accent.withAlphaComponent(0.35).usingColorSpace(.deviceRGB)?.cgColor
                : nil
        }
    }

    private func configureAccessibility(snapshot: SidebarWorkspaceGroupRowSnapshot) {
        setAccessibilityIdentifier("sidebarWorkspaceGroup.\(snapshot.groupId.uuidString)")
        setAccessibilityLabel(snapshot.name)
        setAccessibilityHelp(String(
            localized: "workspaceGroup.focusAnchor.a11y",
            defaultValue: "Focus the group’s anchor workspace"
        ))
        setAccessibilitySelected(snapshot.isAnchorActive)
        if snapshot.anchorUnreadCount > 0 {
            setAccessibilityValue(String.localizedStringWithFormat(
                String(localized: "workspaceGroup.unread.a11y", defaultValue: "%lld unread"),
                Int64(snapshot.anchorUnreadCount)
            ))
        } else {
            setAccessibilityValue(nil)
        }
        addButton.setAccessibilityLabel(String(
            localized: "workspaceGroup.newWorkspaceInGroup.a11y",
            defaultValue: "New workspace in group"
        ))
    }

    private func updateAddButtonVisibility() {
        let visible = isPointerInside && shortcutLabel.isHidden
        addButton.isHidden = !visible
        addButton.setAccessibilityElement(visible)
    }

    private func updateDropIndicatorColors() {
        let color = cmuxAccentNSColor(for: effectiveAppearance)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            topDropIndicator.layer?.backgroundColor = color.usingColorSpace(.deviceRGB)?.cgColor
            bottomDropIndicator.layer?.backgroundColor = color.usingColorSpace(.deviceRGB)?.cgColor
        }
    }

    @objc private func toggleCollapsed() {
        actions.onToggleCollapsed()
    }

    @objc private func addWorkspace() {
        actions.onAddWorkspace()
    }
}
