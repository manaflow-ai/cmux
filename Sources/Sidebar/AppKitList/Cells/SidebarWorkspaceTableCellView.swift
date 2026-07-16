import AppKit
import CmuxFoundation
import CmuxWorkspaces
import Foundation

/// Pure-AppKit workspace row cell for the sidebar table: renders everything
/// the SwiftUI `TabItemView` rendered, from the same immutable
/// `SidebarWorkspaceRowSnapshot`. Subviews are built once in `init`;
/// `configure` only updates values and `isHidden` flags.
@MainActor
final class SidebarWorkspaceTableCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("SidebarWorkspaceTableCellView")

    private(set) var representedWorkspaceId: UUID?

    private struct ConfigurationInputs {
        let snapshot: SidebarWorkspaceRowSnapshot
        let environment: SidebarWorkspaceListEnvironment
        let isPointerHovering: Bool
        let isContextMenuOpen: Bool
        let isEditing: Bool
        let actions: SidebarWorkspaceRowActions?
        let host: SidebarWorkspaceCellHost?
    }

    private var inputs: ConfigurationInputs?

    // Row chrome
    private let rootView = NSView()
    private let backgroundView = NSView()
    private let railView = NSView()
    private let contentStack = SidebarWorkspaceCellStackFactory.vertical(spacing: 4, alignment: .width)
    private let hintPill = SidebarWorkspaceCellHintPillView()
    private let topDropBar = NSView()
    private let bottomDropBar = NSView()

    // Content sections
    private let titleRow = SidebarWorkspaceCellTitleRow()
    private let details = SidebarWorkspaceCellDetails()
    private let metadataSection = SidebarWorkspaceCellMetadataSection()
    private let branchDirectorySection = SidebarWorkspaceCellBranchDirectorySection()
    private let pullRequestsSection = SidebarWorkspaceCellPullRequestsSection()
    private let checklistSection = SidebarWorkspaceCellChecklistSection()

    // Updatable constraints
    private var rootLeadingConstraint: NSLayoutConstraint?
    private var hintTopConstraint: NSLayoutConstraint?
    private var hintTrailingConstraint: NSLayoutConstraint?
    private var topDropBarOffsetConstraint: NSLayoutConstraint?
    private var bottomDropBarOffsetConstraint: NSLayoutConstraint?
    private var sizingWidthConstraint: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
        wantsLayer = true
        layer?.masksToBounds = false
        buildViewHierarchy()
    }

    required init?(coder: NSCoder) { nil }

    private func buildViewHierarchy() {
        rootView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rootView)
        let rootLeading = rootView.leadingAnchor.constraint(
            equalTo: leadingAnchor,
            constant: SidebarWorkspaceListMetrics.rowOuterHorizontalPadding
        )
        rootLeadingConstraint = rootLeading
        NSLayoutConstraint.activate([
            rootLeading,
            rootView.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -SidebarWorkspaceListMetrics.rowOuterHorizontalPadding
            ),
            rootView.topAnchor.constraint(equalTo: topAnchor),
            rootView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = 6
        backgroundView.layer?.cornerCurve = .continuous
        rootView.addSubview(backgroundView)
        NSLayoutConstraint.activate([
            backgroundView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            backgroundView.topAnchor.constraint(equalTo: rootView.topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
        ])

        railView.translatesAutoresizingMaskIntoConstraints = false
        railView.wantsLayer = true
        railView.layer?.cornerRadius = 1.5
        railView.layer?.cornerCurve = .continuous
        backgroundView.addSubview(railView)
        NSLayoutConstraint.activate([
            railView.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: 3),
            railView.widthAnchor.constraint(equalToConstant: 3),
            railView.topAnchor.constraint(equalTo: backgroundView.topAnchor, constant: 5),
            railView.bottomAnchor.constraint(equalTo: backgroundView.bottomAnchor, constant: -5),
        ])

        contentStack.addArrangedSubview(titleRow)
        contentStack.addArrangedSubview(details.descriptionLabel)
        contentStack.addArrangedSubview(details.subtitleLabel)
        contentStack.addArrangedSubview(details.remoteRow)
        contentStack.addArrangedSubview(metadataSection)
        contentStack.addArrangedSubview(details.logRow)
        contentStack.addArrangedSubview(details.progressColumn)
        contentStack.addArrangedSubview(branchDirectorySection)
        contentStack.addArrangedSubview(pullRequestsSection)
        contentStack.addArrangedSubview(details.portsRow)
        contentStack.addArrangedSubview(checklistSection)
        backgroundView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(
                equalTo: backgroundView.leadingAnchor,
                constant: SidebarWorkspaceListMetrics.rowContentHorizontalPadding
            ),
            contentStack.trailingAnchor.constraint(
                equalTo: backgroundView.trailingAnchor,
                constant: -SidebarWorkspaceListMetrics.rowContentHorizontalPadding
            ),
            contentStack.topAnchor.constraint(equalTo: backgroundView.topAnchor, constant: 8),
            contentStack.bottomAnchor.constraint(equalTo: backgroundView.bottomAnchor, constant: -8),
        ])

        addSubview(hintPill)
        let hintTop = hintPill.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 6)
        let hintTrailing = hintPill.trailingAnchor.constraint(
            equalTo: rootView.trailingAnchor,
            constant: -10
        )
        hintTopConstraint = hintTop
        hintTrailingConstraint = hintTrailing
        NSLayoutConstraint.activate([hintTop, hintTrailing])

        for bar in [topDropBar, bottomDropBar] {
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.wantsLayer = true
            addSubview(bar)
        }
        let topOffset = topDropBar.topAnchor.constraint(equalTo: topAnchor)
        let bottomOffset = bottomDropBar.bottomAnchor.constraint(equalTo: bottomAnchor)
        topDropBarOffsetConstraint = topOffset
        bottomDropBarOffsetConstraint = bottomOffset
        NSLayoutConstraint.activate([
            topOffset,
            topDropBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            topDropBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            topDropBar.heightAnchor.constraint(equalToConstant: 2),
            bottomOffset,
            bottomDropBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            bottomDropBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            bottomDropBar.heightAnchor.constraint(equalToConstant: 2),
        ])
    }

    // MARK: - Configure

    func configure(
        snapshot: SidebarWorkspaceRowSnapshot,
        environment: SidebarWorkspaceListEnvironment,
        isPointerHovering: Bool,
        isContextMenuOpen: Bool,
        isEditing: Bool,
        actions: SidebarWorkspaceRowActions?,
        host: SidebarWorkspaceCellHost?
    ) {
        if representedWorkspaceId != snapshot.workspaceId {
            titleRow.endRenameSession()
            checklistSection.dismissPopover()
        }
        representedWorkspaceId = snapshot.workspaceId
        inputs = ConfigurationInputs(
            snapshot: snapshot,
            environment: environment,
            isPointerHovering: isPointerHovering,
            isContextMenuOpen: isContextMenuOpen,
            isEditing: isEditing,
            actions: actions,
            host: host
        )
        applyConfiguration()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Colors are resolved against the appearance at configure time.
        applyConfiguration()
    }

    private func applyConfiguration() {
        guard let inputs else { return }
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let style = SidebarWorkspaceCellStyle(
            snapshot: inputs.snapshot,
            environment: inputs.environment,
            isDarkAppearance: isDark
        )
        let context = SidebarWorkspaceCellContext(
            style: style,
            isPointerHovering: inputs.isPointerHovering,
            isContextMenuOpen: inputs.isContextMenuOpen,
            isEditing: inputs.isEditing,
            actions: inputs.actions,
            host: inputs.host
        )

        applyRowChrome(context)
        titleRow.update(context)
        details.update(context)
        metadataSection.update(context)
        branchDirectorySection.update(context)
        pullRequestsSection.update(context)
        checklistSection.update(context)
        applyAccessibility(context)
    }

    private func applyRowChrome(_ context: SidebarWorkspaceCellContext) {
        let style = context.style
        let snapshot = context.snapshot

        rootLeadingConstraint?.constant = SidebarWorkspaceListMetrics.rowOuterHorizontalPadding
            + (snapshot.groupId != nil ? SidebarWorkspaceGroupingMetrics.memberIndent : 0)

        let background = style.rowBackgroundStyle
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if let color = background.color {
                backgroundView.layer?.backgroundColor = color
                    .withAlphaComponent(color.alphaComponent * CGFloat(background.opacity))
                    .cgColor
            } else {
                backgroundView.layer?.backgroundColor = NSColor.clear.cgColor
            }
            if let borderColor = style.activeBorderColor {
                backgroundView.layer?.borderWidth = 1.5
                backgroundView.layer?.borderColor = borderColor.cgColor
            } else {
                backgroundView.layer?.borderWidth = 0
                backgroundView.layer?.borderColor = nil
            }
            if let railColor = style.railColor {
                railView.isHidden = false
                railView.layer?.backgroundColor = railColor.cgColor
            } else {
                railView.isHidden = true
            }
            let accent = style.accent.cgColor
            topDropBar.layer?.backgroundColor = accent
            bottomDropBar.layer?.backgroundColor = accent
        }

        // Done rows read as settled: dim the content, not the background.
        contentStack.alphaValue = context.workspace.taskStatus == .done ? 0.6 : 1
        rootView.alphaValue = snapshot.isBeingDragged ? 0.6 : 1

        updateHintPill(context)

        topDropBar.isHidden = !snapshot.topDropIndicatorVisible
        bottomDropBar.isHidden = !snapshot.bottomDropIndicatorVisible
        let rowSpacing = snapshot.rowSpacing
        topDropBarOffsetConstraint?.constant = snapshot.index == 0 ? 0 : -(rowSpacing / 2)
        bottomDropBarOffsetConstraint?.constant = rowSpacing / 2

        toolTip = context.workspace.title
    }

    private func updateHintPill(_ context: SidebarWorkspaceCellContext) {
        let snapshot = context.snapshot
        let label: String? = snapshot.workspaceShortcutDigit.map {
            "\(snapshot.workspaceShortcutModifierSymbol)\($0)"
        }
        let shows = context.showsShortcutHints && label != nil
        hintPill.isHidden = !shows
        guard shows, let label else { return }
        let style = context.style
        hintPill.update(
            text: label,
            fontSize: style.fontSize(10),
            emphasis: style.isActive ? 1.0 : 0.9
        )
        hintTopConstraint?.constant = 6
            + ShortcutHintDebugSettings.clamped(context.settings.sidebarShortcutHintYOffset)
        hintTrailingConstraint?.constant = -10
            + ShortcutHintDebugSettings.clamped(context.settings.sidebarShortcutHintXOffset)
    }

    private func applyAccessibility(_ context: SidebarWorkspaceCellContext) {
        let snapshot = context.snapshot
        setAccessibilityIdentifier("sidebarWorkspace.\(snapshot.workspaceId.uuidString)")
        // While renaming, expose children so the inline field stays reachable
        // (mirrors SidebarRowAccessibilityModifier's contain-vs-combine split).
        guard !context.isEditing else {
            setAccessibilityElement(false)
            setAccessibilityCustomActions([])
            return
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        let title = context.workspace.title
        let position = snapshot.index + 1
        let count = snapshot.workspaceCount
        setAccessibilityLabel(String(
            localized: "accessibility.workspacePosition",
            defaultValue: "\(title), workspace \(position) of \(count)"
        ))
        setAccessibilityHelp(String(
            localized: "sidebar.workspace.accessibilityHint",
            defaultValue: "Activate to focus this workspace. Drag to reorder, or use Move Up and Move Down actions."
        ))
        guard let actions = context.actions else {
            setAccessibilityCustomActions([])
            return
        }
        let moveUp = NSAccessibilityCustomAction(
            name: String(localized: "sidebar.workspace.moveUpAction", defaultValue: "Move Up")
        ) {
            actions.moveBy(-1)
            return true
        }
        let moveDown = NSAccessibilityCustomAction(
            name: String(localized: "sidebar.workspace.moveDownAction", defaultValue: "Move Down")
        ) {
            actions.moveBy(1)
            return true
        }
        setAccessibilityCustomActions([moveUp, moveDown])
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        titleRow.endRenameSession()
        checklistSection.dismissPopover()
    }
}

// MARK: - Height measurement

extension SidebarWorkspaceTableCellView: SidebarWorkspaceListSizingCell {
    func configureForSizing(row: SidebarWorkspaceListRow, environment: SidebarWorkspaceListEnvironment) {
        guard case .workspace(let snapshot) = row.content else { return }
        configure(
            snapshot: snapshot,
            environment: environment,
            isPointerHovering: false,
            isContextMenuOpen: false,
            isEditing: false,
            actions: nil,
            host: nil
        )
    }

    func fittingHeight(forWidth width: CGFloat) -> CGFloat {
        guard width > 0 else { return 1 }
        let horizontalInsets = (rootLeadingConstraint?.constant ?? 0)
            + SidebarWorkspaceListMetrics.rowOuterHorizontalPadding
        let rootWidth = max(1, width - horizontalInsets)
        let widthConstraint: NSLayoutConstraint
        if let sizingWidthConstraint {
            widthConstraint = sizingWidthConstraint
        } else {
            widthConstraint = rootView.widthAnchor.constraint(equalToConstant: rootWidth)
            sizingWidthConstraint = widthConstraint
            widthConstraint.isActive = true
        }
        widthConstraint.constant = rootWidth
        // Generous height so the pinned edges never fight the content during
        // measurement; only the width matters for wrapping.
        setFrameSize(NSSize(width: width, height: 10_000))
        // Two passes: the first lets wrapping labels learn their laid-out
        // width (updating preferredMaxLayoutWidth), the second applies the
        // resulting intrinsic heights.
        layoutSubtreeIfNeeded()
        layoutSubtreeIfNeeded()
        return ceil(max(1, rootView.fittingSize.height))
    }
}
