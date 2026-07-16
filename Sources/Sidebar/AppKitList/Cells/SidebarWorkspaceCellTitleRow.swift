import AppKit
import CmuxFoundation
import CmuxSettings
import Foundation

/// The workspace row's title line: leading status slot, pin glyph,
/// media-activity glyphs, title (or the inline-rename field), and the
/// trailing status slot with the hover close button. AppKit port of the
/// title `HStack` in `TabItemView`.
final class SidebarWorkspaceCellTitleRow: NSView {
    private static let maxWrappedTitleLines = 8
    private static let maxDisplayedTitleCharacters = 2048

    private let stack = SidebarWorkspaceCellStackFactory.horizontal(spacing: 8, alignment: .top)

    private let leadingSlot = SidebarWorkspaceCellLeadingStatusSlotView()
    private let leadingSlotBox: SidebarWorkspaceCellFirstLineBox

    private let pinIcon = SidebarWorkspaceCellIconView()
    private let pinBox: SidebarWorkspaceCellFirstLineBox

    private let audioIcon = SidebarWorkspaceCellIconView()
    private let audioBox: SidebarWorkspaceCellFirstLineBox
    private let micIcon = SidebarWorkspaceCellIconView()
    private let micBox: SidebarWorkspaceCellFirstLineBox
    private let cameraIcon = SidebarWorkspaceCellIconView()
    private let cameraBox: SidebarWorkspaceCellFirstLineBox

    private let titleLabel = SidebarWorkspaceCellLabel()

    private let renameContainer = NSView()
    private var renameField: SidebarInlineRenameTextField?
    private var renameCoordinator: SidebarInlineRenameCoordinator?
    private var renameBaselineTitle = ""
    private var renameBaselineHadUserCustomTitle = false

    private let trailingSlot = SidebarWorkspaceCellTrailingStatusSlotView()
    private let trailingSlotBox: SidebarWorkspaceCellFirstLineBox

    override init(frame frameRect: NSRect) {
        leadingSlotBox = SidebarWorkspaceCellFirstLineBox(child: leadingSlot)
        pinBox = SidebarWorkspaceCellFirstLineBox(child: pinIcon)
        audioBox = SidebarWorkspaceCellFirstLineBox(child: audioIcon)
        micBox = SidebarWorkspaceCellFirstLineBox(child: micIcon)
        cameraBox = SidebarWorkspaceCellFirstLineBox(child: cameraIcon)
        trailingSlotBox = SidebarWorkspaceCellFirstLineBox(child: trailingSlot)
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.wrapsText = true
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        renameContainer.translatesAutoresizingMaskIntoConstraints = false
        renameContainer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        renameContainer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        stack.addArrangedSubview(leadingSlotBox)
        stack.addArrangedSubview(pinBox)
        stack.addArrangedSubview(audioBox)
        stack.addArrangedSubview(micBox)
        stack.addArrangedSubview(cameraBox)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(renameContainer)
        // Trailing gravity pins the status slot / close button to the row's
        // trailing edge; leading-gravity views cluster left and the gap
        // absorbs the slack (gravity areas do not stretch children).
        stack.addView(trailingSlotBox, in: .trailing)

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func update(_ context: SidebarWorkspaceCellContext) {
        let style = context.style
        let snapshot = context.snapshot
        let workspace = context.workspace
        let settings = context.settings

        let showsLoadingSpinner = snapshot.showsAgentActivity && workspace.activeCodingAgentCount > 0
        let badgeOnLeading = snapshot.unreadCount > 0 && settings.notificationBadgePosition == .leading
        let badgeOnTrailing = snapshot.unreadCount > 0 && settings.notificationBadgePosition == .trailing
        let spinnerOnLeading = showsLoadingSpinner && settings.loadingSpinnerPosition == .leading
        let spinnerOnTrailing = showsLoadingSpinner && settings.loadingSpinnerPosition == .trailing
        let leadingSlotActive = badgeOnLeading || spinnerOnLeading
        let trailingStatusActive = badgeOnTrailing || spinnerOnTrailing

        stack.spacing = spinnerOnLeading ? 6 : 8

        let badgeSide = style.scaledSize(16)
        let spinnerSide = max(10, style.scaledSize(12))
        let badgeFont = SidebarWorkspaceCellFonts.system(style.fontSize(9), weight: .semibold)
        let spinnerTooltip = SidebarWorkspaceLoadingTooltip.text(count: workspace.activeCodingAgentCount)
        let firstLineCenter = style.fontSize(12.5) * 0.6

        leadingSlotBox.isHidden = !leadingSlotActive
        if leadingSlotActive {
            leadingSlot.update(
                showsBadge: badgeOnLeading,
                showsSpinner: spinnerOnLeading,
                unreadCount: snapshot.unreadCount,
                badgeSide: badgeSide,
                spinnerSide: spinnerSide,
                badgeFont: badgeFont,
                badgeFill: style.unreadBadgeFill,
                badgeText: style.unreadBadgeText,
                spinnerColor: style.spinnerColor,
                spinnerTooltip: spinnerTooltip
            )
            leadingSlotBox.setFirstLineCenter(
                firstLineCenter,
                childHeight: badgeOnLeading ? badgeSide : spinnerSide
            )
        }

        let protectedWorkspaceTooltip = String(
            localized: "sidebar.pinnedWorkspaceProtected.tooltip",
            defaultValue: "Pinned workspace. Closing requires confirmation."
        )
        pinBox.isHidden = !workspace.isPinned
        if workspace.isPinned {
            let pinSize = style.fontSize(9)
            pinIcon.setSymbol("pin.fill", pointSize: pinSize, weight: .semibold, color: style.secondary(0.8))
            pinIcon.toolTip = protectedWorkspaceTooltip
            pinBox.setFirstLineCenter(firstLineCenter, childHeight: pinSize)
        }

        updateMediaIndicators(context, firstLineCenter: firstLineCenter)
        updateTitleOrRename(context)

        trailingSlotBox.isHidden = !(trailingStatusActive || snapshot.canCloseWorkspace)
        if trailingStatusActive || snapshot.canCloseWorkspace {
            let closeHitSize = max(16, style.scaledSize(16))
            let closeWidth = max(SidebarTrailingAccessoryWidthPolicy().closeButtonWidth, closeHitSize)
            let closeWorkspaceTooltip = String(
                localized: "sidebar.closeWorkspace.tooltip",
                defaultValue: "Close Workspace"
            )
            let closeButtonTooltip = workspace.isPinned
                ? protectedWorkspaceTooltip
                : KeyboardShortcutSettings.Action.closeWorkspace.tooltip(closeWorkspaceTooltip)
            let actions = context.actions
            trailingSlot.update(
                showsSpinner: spinnerOnTrailing,
                showsBadge: badgeOnTrailing,
                unreadCount: snapshot.unreadCount,
                badgeSide: badgeSide,
                width: closeWidth,
                height: closeHitSize,
                badgeFont: badgeFont,
                badgeFill: style.unreadBadgeFill,
                badgeText: style.unreadBadgeText,
                spinnerColor: style.spinnerColor,
                spinnerTooltip: spinnerTooltip,
                canCloseWorkspace: snapshot.canCloseWorkspace,
                showsCloseButton: context.showsCloseButton,
                closeButtonTooltip: closeButtonTooltip,
                closeButtonColor: style.secondary(0.7),
                closeButtonFontSize: style.fontSize(9),
                closeAction: actions.map { resolved in { resolved.closeWorkspace() } }
            )
            trailingSlotBox.setFirstLineCenter(firstLineCenter, childHeight: closeHitSize)
        }
    }

    private func updateMediaIndicators(_ context: SidebarWorkspaceCellContext, firstLineCenter: CGFloat) {
        let style = context.style
        let media = context.workspace.mediaActivity
        let size = style.fontSize(9)

        audioBox.isHidden = !media.isPlayingAudio
        if media.isPlayingAudio {
            audioIcon.setSymbol("speaker.wave.2.fill", pointSize: size, weight: .semibold, color: style.secondary(0.8))
            audioIcon.toolTip = String(
                localized: "sidebar.mediaActivity.audio.tooltip",
                defaultValue: "Playing audio"
            )
            audioBox.setFirstLineCenter(firstLineCenter, childHeight: size)
        }
        micBox.isHidden = !media.isUsingMicrophone
        if media.isUsingMicrophone {
            micIcon.setSymbol("mic.fill", pointSize: size, weight: .semibold, color: .systemOrange)
            micIcon.toolTip = String(
                localized: "sidebar.mediaActivity.microphone.tooltip",
                defaultValue: "Microphone in use"
            )
            micBox.setFirstLineCenter(firstLineCenter, childHeight: size)
        }
        cameraBox.isHidden = !media.isUsingCamera
        if media.isUsingCamera {
            cameraIcon.setSymbol("video.fill", pointSize: size, weight: .semibold, color: .systemGreen)
            cameraIcon.toolTip = String(
                localized: "sidebar.mediaActivity.camera.tooltip",
                defaultValue: "Camera in use"
            )
            cameraBox.setFirstLineCenter(firstLineCenter, childHeight: size)
        }
    }

    private func updateTitleOrRename(_ context: SidebarWorkspaceCellContext) {
        let style = context.style
        if context.isEditing, context.actions != nil {
            titleLabel.isHidden = true
            renameContainer.isHidden = false
            beginRenameSessionIfNeeded(context)
        } else {
            endRenameSession()
            renameContainer.isHidden = true
            titleLabel.isHidden = false
            let titleLineLimit = context.settings.wrapsWorkspaceTitles ? Self.maxWrappedTitleLines : 1
            titleLabel.maximumNumberOfLines = titleLineLimit
            titleLabel.font = SidebarWorkspaceCellFonts.system(style.fontSize(12.5), weight: .semibold)
            titleLabel.textColor = style.primaryText
            titleLabel.stringValue = context.workspace.title.sidebarCellBoundedDisplayString(
                maxDisplayedLines: titleLineLimit,
                maxDisplayedCharacters: Self.maxDisplayedTitleCharacters
            )
        }
    }

    private func beginRenameSessionIfNeeded(_ context: SidebarWorkspaceCellContext) {
        guard renameField == nil, let actions = context.actions, let host = context.host else { return }
        renameBaselineTitle = context.workspace.title
        renameBaselineHadUserCustomTitle = context.snapshot.hasUserCustomTitle

        let coordinator = SidebarInlineRenameCoordinator(
            onCommit: { [weak self] draft in
                guard let self else { return }
                if let title = SidebarInlineRenameCommit().titleToCommit(
                    draft: draft,
                    baseline: self.renameBaselineTitle,
                    baselineHadUserCustomTitle: self.renameBaselineHadUserCustomTitle
                ) {
                    actions.setCustomTitle(title)
                }
                host.endRename()
            },
            onCancel: {
                host.endRename()
            }
        )
        renameCoordinator = coordinator

        let field = SidebarInlineRenameTextField(string: renameBaselineTitle)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.font = SidebarWorkspaceCellFonts.system(context.style.fontSize(12.5), weight: .semibold)
        field.inlineRenameTextColor = context.style.selectedForeground(1.0)
        field.placeholderString = String(
            localized: "commandPalette.rename.workspacePlaceholder",
            defaultValue: "Workspace name"
        )
        field.setAccessibilityLabel(String(
            localized: "sidebar.workspace.rename.field.accessibilityLabel",
            defaultValue: "Rename workspace"
        ))
        field.delegate = coordinator
        renameField = field

        renameContainer.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: renameContainer.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: renameContainer.trailingAnchor),
            field.topAnchor.constraint(equalTo: renameContainer.topAnchor),
            field.bottomAnchor.constraint(equalTo: renameContainer.bottomAnchor),
        ])
    }

    /// Tears down the rename field without committing (the coordinator's
    /// once-guard means a commit/cancel that already ran stays authoritative).
    func endRenameSession() {
        guard let field = renameField else { return }
        if field.currentEditor() != nil {
            field.window?.makeFirstResponder(nil)
        }
        field.delegate = nil
        field.removeFromSuperview()
        renameField = nil
        renameCoordinator = nil
    }
}
