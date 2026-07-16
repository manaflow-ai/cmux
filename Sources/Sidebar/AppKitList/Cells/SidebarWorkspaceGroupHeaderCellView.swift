import AppKit
import CmuxFoundation

/// Pure-AppKit port of `SidebarWorkspaceGroupHeaderView`: the collapsible
/// workspace-group header row that doubles as the group's anchor workspace.
///
/// Renders exclusively from `SidebarWorkspaceGroupRowSnapshot` plus the
/// `SidebarWorkspaceGroupHeaderActions` closure bundle. Subviews are built
/// once in `init`; `configure` only updates values, visibility, and
/// constraint constants. Row clicks (focus anchor), hover, drag, and the
/// row-level context menu are owned by the table/controller; this cell owns
/// the chevron, the hover-revealed `+` button (including its right-click
/// menu), the unread badge, the shortcut-hint pill, and the drop indicators.
@MainActor
final class SidebarWorkspaceGroupHeaderCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("SidebarWorkspaceGroupHeaderCellView")

    // MARK: - Subviews

    private let contentContainer = NSView()
    private let highlightView = NSView()
    private let rowStack = NSStackView()
    private let pinImageView = NSImageView()
    private let chevronButton = SidebarWorkspaceGroupHeaderCellGlyphButton()
    private let iconImageView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let unreadBadgeView = NSView()
    private let unreadLabel = NSTextField(labelWithString: "")
    private let flexibleSpacer = NSView()
    private let plusButton = SidebarWorkspaceGroupHeaderCellGlyphButton()
    private let shortcutHintPill = SidebarWorkspaceGroupHeaderCellShortcutHintPillView()
    private let topDropIndicator = NSView()
    private let bottomDropIndicator = NSView()

    // MARK: - Mutable constraints

    private var pinWidthConstraint: NSLayoutConstraint!
    private var pinHeightConstraint: NSLayoutConstraint!
    private var chevronWidthConstraint: NSLayoutConstraint!
    private var chevronHeightConstraint: NSLayoutConstraint!
    private var iconWidthConstraint: NSLayoutConstraint!
    private var iconHeightConstraint: NSLayoutConstraint!
    private var plusWidthConstraint: NSLayoutConstraint!
    private var plusHeightConstraint: NSLayoutConstraint!
    private var unreadLeadingConstraint: NSLayoutConstraint!
    private var unreadTrailingConstraint: NSLayoutConstraint!
    private var unreadTopConstraint: NSLayoutConstraint!
    private var unreadBottomConstraint: NSLayoutConstraint!
    private var pillTopConstraint: NSLayoutConstraint!
    private var pillTrailingConstraint: NSLayoutConstraint!
    private var topIndicatorTopConstraint: NSLayoutConstraint!
    private var topIndicatorLeadingConstraint: NSLayoutConstraint!
    private var bottomIndicatorBottomConstraint: NSLayoutConstraint!
    private var bottomIndicatorLeadingConstraint: NSLayoutConstraint!

    // MARK: - State

    private var snapshot: SidebarWorkspaceGroupRowSnapshot?
    private var environment: SidebarWorkspaceListEnvironment = .default
    private var actions: SidebarWorkspaceGroupHeaderActions?

    // MARK: - Static metrics shared with the SwiftUI header

    private static let rowVerticalPadding: CGFloat = 5
    private static let highlightCornerRadius: CGFloat = 4
    private static let dropIndicatorHeight: CGFloat = 2
    private static let dropIndicatorHorizontalPadding: CGFloat = 8
    private static let hintPillBaseFontSize: CGFloat = 10
    private static let hintPillTopPadding: CGFloat = 6
    private static let hintPillTrailingPadding: CGFloat = 10
    private static let draggedRowAlpha: CGFloat = 0.6

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
        buildViewHierarchy()
        activateConstraints()
        configureStaticViewProperties()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func buildViewHierarchy() {
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.wantsLayer = true
        addSubview(contentContainer)

        highlightView.translatesAutoresizingMaskIntoConstraints = false
        highlightView.wantsLayer = true
        contentContainer.addSubview(highlightView)

        rowStack.translatesAutoresizingMaskIntoConstraints = false
        rowStack.orientation = .horizontal
        rowStack.alignment = .centerY
        rowStack.distribution = .fill
        rowStack.spacing = 4
        highlightView.addSubview(rowStack)

        unreadLabel.translatesAutoresizingMaskIntoConstraints = false
        unreadBadgeView.translatesAutoresizingMaskIntoConstraints = false
        unreadBadgeView.wantsLayer = true
        unreadBadgeView.addSubview(unreadLabel)

        rowStack.addArrangedSubview(pinImageView)
        rowStack.addArrangedSubview(chevronButton)
        rowStack.addArrangedSubview(iconImageView)
        rowStack.addArrangedSubview(nameLabel)
        rowStack.addArrangedSubview(unreadBadgeView)
        rowStack.addArrangedSubview(flexibleSpacer)
        rowStack.addArrangedSubview(plusButton)
        rowStack.setCustomSpacing(6, after: iconImageView)
        rowStack.setCustomSpacing(0, after: unreadBadgeView)
        rowStack.setCustomSpacing(4, after: flexibleSpacer)

        shortcutHintPill.translatesAutoresizingMaskIntoConstraints = false
        highlightView.addSubview(shortcutHintPill)

        topDropIndicator.translatesAutoresizingMaskIntoConstraints = false
        topDropIndicator.wantsLayer = true
        addSubview(topDropIndicator)

        bottomDropIndicator.translatesAutoresizingMaskIntoConstraints = false
        bottomDropIndicator.wantsLayer = true
        addSubview(bottomDropIndicator)
    }

    private func activateConstraints() {
        pinImageView.translatesAutoresizingMaskIntoConstraints = false
        chevronButton.translatesAutoresizingMaskIntoConstraints = false
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        plusButton.translatesAutoresizingMaskIntoConstraints = false
        flexibleSpacer.translatesAutoresizingMaskIntoConstraints = false

        pinWidthConstraint = pinImageView.widthAnchor.constraint(equalToConstant: 14)
        pinHeightConstraint = pinImageView.heightAnchor.constraint(equalToConstant: 14)
        chevronWidthConstraint = chevronButton.widthAnchor.constraint(equalToConstant: 14)
        chevronHeightConstraint = chevronButton.heightAnchor.constraint(equalToConstant: 14)
        iconWidthConstraint = iconImageView.widthAnchor.constraint(equalToConstant: 14)
        iconHeightConstraint = iconImageView.heightAnchor.constraint(equalToConstant: 14)
        plusWidthConstraint = plusButton.widthAnchor.constraint(equalToConstant: 16)
        plusHeightConstraint = plusButton.heightAnchor.constraint(equalToConstant: 16)

        unreadLeadingConstraint = unreadLabel.leadingAnchor.constraint(
            equalTo: unreadBadgeView.leadingAnchor,
            constant: 5
        )
        unreadTrailingConstraint = unreadLabel.trailingAnchor.constraint(
            equalTo: unreadBadgeView.trailingAnchor,
            constant: -5
        )
        unreadTopConstraint = unreadLabel.topAnchor.constraint(
            equalTo: unreadBadgeView.topAnchor,
            constant: 1
        )
        unreadBottomConstraint = unreadLabel.bottomAnchor.constraint(
            equalTo: unreadBadgeView.bottomAnchor,
            constant: -1
        )

        pillTopConstraint = shortcutHintPill.topAnchor.constraint(
            equalTo: highlightView.topAnchor,
            constant: Self.hintPillTopPadding
        )
        pillTrailingConstraint = shortcutHintPill.trailingAnchor.constraint(
            equalTo: highlightView.trailingAnchor,
            constant: -Self.hintPillTrailingPadding
        )

        topIndicatorTopConstraint = topDropIndicator.topAnchor.constraint(
            equalTo: topAnchor,
            constant: 0
        )
        topIndicatorLeadingConstraint = topDropIndicator.leadingAnchor.constraint(
            equalTo: leadingAnchor,
            constant: Self.dropIndicatorHorizontalPadding
        )
        bottomIndicatorBottomConstraint = bottomDropIndicator.bottomAnchor.constraint(
            equalTo: bottomAnchor,
            constant: 0
        )
        bottomIndicatorLeadingConstraint = bottomDropIndicator.leadingAnchor.constraint(
            equalTo: leadingAnchor,
            constant: Self.dropIndicatorHorizontalPadding
        )

        NSLayoutConstraint.activate([
            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

            highlightView.leadingAnchor.constraint(
                equalTo: contentContainer.leadingAnchor,
                constant: SidebarWorkspaceListMetrics.rowOuterHorizontalPadding
            ),
            highlightView.trailingAnchor.constraint(
                equalTo: contentContainer.trailingAnchor,
                constant: -SidebarWorkspaceListMetrics.rowOuterHorizontalPadding
            ),
            highlightView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            highlightView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),

            rowStack.leadingAnchor.constraint(equalTo: highlightView.leadingAnchor),
            rowStack.trailingAnchor.constraint(
                equalTo: highlightView.trailingAnchor,
                constant: -SidebarWorkspaceListMetrics.rowContentHorizontalPadding
            ),
            rowStack.centerYAnchor.constraint(equalTo: highlightView.centerYAnchor),

            pinWidthConstraint, pinHeightConstraint,
            chevronWidthConstraint, chevronHeightConstraint,
            iconWidthConstraint, iconHeightConstraint,
            plusWidthConstraint, plusHeightConstraint,
            unreadLeadingConstraint, unreadTrailingConstraint,
            unreadTopConstraint, unreadBottomConstraint,
            flexibleSpacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 0),

            pillTopConstraint, pillTrailingConstraint,

            topIndicatorTopConstraint,
            topIndicatorLeadingConstraint,
            topDropIndicator.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -Self.dropIndicatorHorizontalPadding
            ),
            topDropIndicator.heightAnchor.constraint(equalToConstant: Self.dropIndicatorHeight),

            bottomIndicatorBottomConstraint,
            bottomIndicatorLeadingConstraint,
            bottomDropIndicator.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -Self.dropIndicatorHorizontalPadding
            ),
            bottomDropIndicator.heightAnchor.constraint(equalToConstant: Self.dropIndicatorHeight),
        ])
    }

    private func configureStaticViewProperties() {
        highlightView.layer?.cornerRadius = Self.highlightCornerRadius
        highlightView.layer?.cornerCurve = .continuous

        pinImageView.imageScaling = .scaleNone
        pinImageView.setAccessibilityElement(true)
        pinImageView.setAccessibilityRole(.image)

        iconImageView.imageScaling = .scaleNone
        iconImageView.setAccessibilityElement(false)

        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        nameLabel.usesSingleLineMode = true
        nameLabel.cell?.truncatesLastVisibleLine = true
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(
            NSLayoutConstraint.Priority(rawValue: 250),
            for: .horizontal
        )

        unreadLabel.textColor = .white
        unreadLabel.maximumNumberOfLines = 1
        unreadLabel.setContentHuggingPriority(.required, for: .horizontal)
        unreadLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        flexibleSpacer.setContentHuggingPriority(
            NSLayoutConstraint.Priority(rawValue: 1),
            for: .horizontal
        )
        flexibleSpacer.setContentCompressionResistancePriority(
            NSLayoutConstraint.Priority(rawValue: 1),
            for: .horizontal
        )

        chevronButton.onClick = { [weak self] in
            self?.actions?.onToggleCollapsed()
        }
        plusButton.onClick = { [weak self] in
            self?.actions?.onTapPlus()
        }
        plusButton.menuProvider = { [weak self] in
            guard let self, let snapshot = self.snapshot, let actions = self.actions else {
                return nil
            }
            return SidebarWorkspaceGroupHeaderContextMenuFactory.makePlusButtonMenu(
                snapshot: snapshot,
                actions: actions
            )
        }
        plusButton.setAccessibilityLabel(
            String(
                localized: "workspaceGroup.newWorkspaceInGroup.a11y",
                defaultValue: "New workspace in group"
            )
        )

        nameLabel.setAccessibilityHelp(
            String(
                localized: "workspaceGroup.focusAnchor.a11y",
                defaultValue: "Focus the group's anchor workspace"
            )
        )

        let pinnedTooltip = String(
            localized: "workspaceGroup.pinned.tooltip",
            defaultValue: "Pinned group"
        )
        pinImageView.toolTip = pinnedTooltip
        pinImageView.setAccessibilityLabel(pinnedTooltip)
    }

    // MARK: - Configure

    func configure(
        snapshot: SidebarWorkspaceGroupRowSnapshot,
        environment: SidebarWorkspaceListEnvironment,
        isPointerHovering: Bool,
        isContextMenuOpen: Bool,
        actions: SidebarWorkspaceGroupHeaderActions?
    ) {
        self.snapshot = snapshot
        self.environment = environment
        self.actions = actions

        let metrics = SidebarWorkspaceGroupHeaderMetrics(fontScale: snapshot.fontScale)

        setAccessibilityIdentifier("sidebarWorkspaceGroup.\(snapshot.groupId.uuidString)")

        configurePin(snapshot: snapshot, metrics: metrics)
        configureChevron(snapshot: snapshot, metrics: metrics)
        configureIcon(snapshot: snapshot, metrics: metrics)
        configureName(snapshot: snapshot, metrics: metrics)
        configureUnreadBadge(snapshot: snapshot, metrics: metrics)
        configurePlusButton(
            snapshot: snapshot,
            metrics: metrics,
            isPointerHovering: isPointerHovering,
            isContextMenuOpen: isContextMenuOpen
        )
        configureShortcutHintPill(snapshot: snapshot)
        configureDropIndicators(snapshot: snapshot, metrics: metrics)

        contentContainer.alphaValue = snapshot.isBeingDragged ? Self.draggedRowAlpha : 1
        applyAppearanceSensitiveColors()
    }

    private func configurePin(
        snapshot: SidebarWorkspaceGroupRowSnapshot,
        metrics: SidebarWorkspaceGroupHeaderMetrics
    ) {
        pinImageView.isHidden = !snapshot.isPinned
        pinWidthConstraint.constant = metrics.iconFrame
        pinHeightConstraint.constant = metrics.iconFrame
        guard snapshot.isPinned else { return }
        pinImageView.image = SidebarWorkspaceGroupHeaderCellSymbol.image(
            systemName: "pin.fill",
            pointSize: environment.fontSize(
                base: SidebarWorkspaceGroupHeaderMetrics.basePinnedIconFontSize,
                sidebarFontScale: snapshot.fontScale
            ),
            weight: .semibold
        )
        pinImageView.contentTintColor = NSColor.secondaryLabelColor.withAlphaComponent(0.8)
    }

    private func configureChevron(
        snapshot: SidebarWorkspaceGroupRowSnapshot,
        metrics: SidebarWorkspaceGroupHeaderMetrics
    ) {
        chevronWidthConstraint.constant = metrics.chevronFrame
        chevronHeightConstraint.constant = metrics.chevronFrame
        chevronButton.image = SidebarWorkspaceGroupHeaderCellSymbol.image(
            systemName: snapshot.isCollapsed ? "chevron.right" : "chevron.down",
            pointSize: environment.fontSize(
                base: SidebarWorkspaceGroupHeaderMetrics.baseChevronFontSize,
                sidebarFontScale: snapshot.fontScale
            ),
            weight: .semibold
        )
        chevronButton.contentTintColor = .secondaryLabelColor
        chevronButton.setAccessibilityLabel(
            snapshot.isCollapsed
                ? String(localized: "workspaceGroup.expand.a11y", defaultValue: "Expand group")
                : String(localized: "workspaceGroup.collapse.a11y", defaultValue: "Collapse group")
        )
    }

    private func configureIcon(
        snapshot: SidebarWorkspaceGroupRowSnapshot,
        metrics: SidebarWorkspaceGroupHeaderMetrics
    ) {
        iconWidthConstraint.constant = metrics.iconFrame
        iconHeightConstraint.constant = metrics.iconFrame
        let resolvedSymbol = RenderableSystemSymbol.resolvedWorkspaceGroupIcon(
            explicit: snapshot.iconSymbol,
            configured: nil
        )
        iconImageView.image = SidebarWorkspaceGroupHeaderCellSymbol.image(
            systemName: resolvedSymbol,
            pointSize: environment.fontSize(
                base: SidebarWorkspaceGroupHeaderMetrics.baseIconFontSize,
                sidebarFontScale: snapshot.fontScale
            ),
            weight: .semibold
        )
        if let tintHex = snapshot.tintHex, let tint = NSColor(hex: tintHex) {
            iconImageView.contentTintColor = tint
        } else {
            iconImageView.contentTintColor = .secondaryLabelColor
        }
    }

    private func configureName(
        snapshot: SidebarWorkspaceGroupRowSnapshot,
        metrics: SidebarWorkspaceGroupHeaderMetrics
    ) {
        nameLabel.stringValue = snapshot.name
        nameLabel.font = NSFont.systemFont(
            ofSize: environment.fontSize(
                base: SidebarWorkspaceGroupHeaderMetrics.baseNameFontSize,
                sidebarFontScale: snapshot.fontScale
            ),
            weight: .semibold
        )
        nameLabel.textColor = snapshot.isAnchorActive
            ? NSColor.labelColor
            : NSColor.labelColor.withAlphaComponent(0.9)
        nameLabel.setAccessibilityLabel(snapshot.name)
    }

    private func configureUnreadBadge(
        snapshot: SidebarWorkspaceGroupRowSnapshot,
        metrics: SidebarWorkspaceGroupHeaderMetrics
    ) {
        let showsUnread = snapshot.anchorUnreadCount > 0
        unreadBadgeView.isHidden = !showsUnread
        rowStack.setCustomSpacing(showsUnread ? 6 : 0, after: nameLabel)
        guard showsUnread else { return }
        unreadLabel.stringValue = "\(snapshot.anchorUnreadCount)"
        unreadLabel.font = NSFont.systemFont(
            ofSize: environment.fontSize(
                base: SidebarWorkspaceGroupHeaderMetrics.baseUnreadFontSize,
                sidebarFontScale: snapshot.fontScale
            ),
            weight: .semibold
        )
        unreadLeadingConstraint.constant = metrics.unreadHorizontalPadding
        unreadTrailingConstraint.constant = -metrics.unreadHorizontalPadding
        unreadTopConstraint.constant = metrics.unreadVerticalPadding
        unreadBottomConstraint.constant = -metrics.unreadVerticalPadding
        unreadBadgeView.setAccessibilityElement(true)
        unreadBadgeView.setAccessibilityRole(.staticText)
        unreadBadgeView.setAccessibilityLabel(
            String.localizedStringWithFormat(
                String(localized: "workspaceGroup.unread.a11y", defaultValue: "%lld unread"),
                snapshot.anchorUnreadCount
            )
        )
    }

    private func configurePlusButton(
        snapshot: SidebarWorkspaceGroupRowSnapshot,
        metrics: SidebarWorkspaceGroupHeaderMetrics,
        isPointerHovering: Bool,
        isContextMenuOpen: Bool
    ) {
        plusWidthConstraint.constant = metrics.plusFrame
        plusHeightConstraint.constant = metrics.plusFrame
        plusButton.image = SidebarWorkspaceGroupHeaderCellSymbol.image(
            systemName: "plus",
            pointSize: environment.fontSize(
                base: SidebarWorkspaceGroupHeaderMetrics.basePlusFontSize,
                sidebarFontScale: snapshot.fontScale
            ),
            weight: .medium
        )
        plusButton.contentTintColor = .secondaryLabelColor

        let plusVisible = isPointerHovering && !isContextMenuOpen && !snapshot.showsShortcutHint
        plusButton.alphaValue = plusVisible ? 1 : 0
        plusButton.isHitTestingEnabled = plusVisible
        plusButton.setAccessibilityElement(plusVisible)
    }

    private func configureShortcutHintPill(snapshot: SidebarWorkspaceGroupRowSnapshot) {
        var pillText: String?
        if snapshot.showsShortcutHint,
           let digit = snapshot.shortcutDigit,
           let modifierSymbol = snapshot.shortcutModifierSymbol {
            pillText = "\(modifierSymbol)\(digit)"
        }
        shortcutHintPill.configure(
            text: pillText,
            fontSize: environment.fontSize(base: Self.hintPillBaseFontSize, sidebarFontScale: 1),
            emphasis: snapshot.isAnchorActive ? 1.0 : 0.9
        )
        pillTopConstraint.constant =
            Self.hintPillTopPadding
            + CGFloat(ShortcutHintDebugSettings.clamped(snapshot.shortcutHintYOffset))
        pillTrailingConstraint.constant =
            -Self.hintPillTrailingPadding
            + CGFloat(ShortcutHintDebugSettings.clamped(snapshot.shortcutHintXOffset))
    }

    private func configureDropIndicators(
        snapshot: SidebarWorkspaceGroupRowSnapshot,
        metrics: SidebarWorkspaceGroupHeaderMetrics
    ) {
        topDropIndicator.isHidden = !snapshot.topDropIndicatorVisible
        topIndicatorTopConstraint.constant =
            snapshot.isFirstRow ? 0 : -(snapshot.rowSpacing / 2)
        topIndicatorLeadingConstraint.constant = Self.dropIndicatorHorizontalPadding

        bottomDropIndicator.isHidden = !snapshot.bottomDropIndicatorVisible
        bottomIndicatorBottomConstraint.constant = snapshot.rowSpacing / 2
        bottomIndicatorLeadingConstraint.constant =
            Self.dropIndicatorHorizontalPadding
            + max(metrics.groupScopedBottomDropIndicatorLeadingInset, 0)
    }

    // MARK: - Appearance

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearanceSensitiveColors()
    }

    override func layout() {
        super.layout()
        unreadBadgeView.layer?.cornerRadius = unreadBadgeView.bounds.height / 2
    }

    private func applyAppearanceSensitiveColors() {
        let isAnchorActive = snapshot?.isAnchorActive ?? false
        let highlightColor = isAnchorActive
            ? NSColor.labelColor.withAlphaComponent(0.08)
            : nil
        setLayerBackgroundColor(of: highlightView, to: highlightColor)
        setLayerBackgroundColor(of: unreadBadgeView, to: .controlAccentColor)
        let accent = cmuxAccentNSColor()
        setLayerBackgroundColor(of: topDropIndicator, to: accent)
        setLayerBackgroundColor(of: bottomDropIndicator, to: accent)
    }

    private func setLayerBackgroundColor(of view: NSView, to color: NSColor?) {
        guard let layer = view.layer else { return }
        guard let color else {
            layer.backgroundColor = nil
            return
        }
        var resolved = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = color.cgColor
        }
        layer.backgroundColor = resolved
    }
}

// MARK: - Sizing

extension SidebarWorkspaceGroupHeaderCellView: SidebarWorkspaceListSizingCell {
    func configureForSizing(
        row: SidebarWorkspaceListRow,
        environment: SidebarWorkspaceListEnvironment
    ) {
        guard case .groupHeader(let snapshot) = row.content else { return }
        configure(
            snapshot: snapshot,
            environment: environment,
            isPointerHovering: false,
            isContextMenuOpen: false,
            actions: nil
        )
    }

    /// Deterministic single-line header height: the tallest of the fixed
    /// control frames and the configured text lines, plus the SwiftUI
    /// header's 5pt top and bottom padding. Width-independent because the
    /// name truncates instead of wrapping.
    func fittingHeight(forWidth width: CGFloat) -> CGFloat {
        guard let snapshot else {
            return SidebarWorkspaceTableRowHeightCalculator().estimatedGroupHeaderHeight(fontScale: 1)
        }
        let metrics = SidebarWorkspaceGroupHeaderMetrics(fontScale: snapshot.fontScale)
        let nameHeight = ceil(nameLabel.intrinsicContentSize.height)
        let unreadHeight: CGFloat
        if snapshot.anchorUnreadCount > 0 {
            unreadHeight = ceil(unreadLabel.intrinsicContentSize.height)
                + metrics.unreadVerticalPadding * 2
        } else {
            unreadHeight = 0
        }
        let contentHeight = max(
            metrics.chevronFrame,
            metrics.iconFrame,
            metrics.plusFrame,
            nameHeight,
            unreadHeight
        )
        return ceil(contentHeight + Self.rowVerticalPadding * 2)
    }
}
