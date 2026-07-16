import AppKit
import Foundation

/// Circular unread-count badge (AppKit port of `SidebarWorkspaceUnreadBadge`).
final class SidebarWorkspaceCellUnreadBadgeView: NSView {
    private let countLabel = SidebarWorkspaceCellLabel()
    private lazy var sideWidth = widthAnchor.constraint(equalToConstant: 16)
    private lazy var sideHeight = heightAnchor.constraint(equalToConstant: 16)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = true
        countLabel.alignment = .center
        countLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(countLabel)
        NSLayoutConstraint.activate([
            sideWidth,
            sideHeight,
            countLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func update(count: Int, side: CGFloat, font: NSFont, fill: NSColor, text: NSColor) {
        sideWidth.constant = side
        sideHeight.constant = side
        countLabel.font = font
        countLabel.stringValue = "\(count)"
        countLabel.textColor = text
        layer?.backgroundColor = fill.cgColor
        needsLayout = true
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }
}

/// The leading status slot before the title: unread badge and/or GPU spinner
/// in one clipped square (AppKit port of `SidebarWorkspaceLeadingStatusSlot`).
final class SidebarWorkspaceCellLeadingStatusSlotView: NSView {
    private let badge = SidebarWorkspaceCellUnreadBadgeView()
    private let spinner = GPUSpinnerNSView(frame: .zero)
    private lazy var slotWidth = widthAnchor.constraint(equalToConstant: 16)
    private lazy var slotHeight = heightAnchor.constraint(equalToConstant: 16)
    private lazy var spinnerWidth = spinner.widthAnchor.constraint(equalToConstant: 12)
    private lazy var spinnerHeight = spinner.heightAnchor.constraint(equalToConstant: 12)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)
        addSubview(spinner)
        NSLayoutConstraint.activate([
            slotWidth,
            slotHeight,
            badge.centerXAnchor.constraint(equalTo: centerXAnchor),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinnerWidth,
            spinnerHeight,
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { nil }

    // swiftlint:disable:next function_parameter_count
    func update(
        showsBadge: Bool,
        showsSpinner: Bool,
        unreadCount: Int,
        badgeSide: CGFloat,
        spinnerSide: CGFloat,
        badgeFont: NSFont,
        badgeFill: NSColor,
        badgeText: NSColor,
        spinnerColor: NSColor,
        spinnerTooltip: String
    ) {
        let slotSide = showsBadge ? badgeSide : spinnerSide
        slotWidth.constant = slotSide
        slotHeight.constant = slotSide
        badge.isHidden = !showsBadge
        // Spinner takes over the slot: badge stays laid out but invisible.
        badge.alphaValue = showsSpinner ? 0 : 1
        if showsBadge {
            badge.update(count: unreadCount, side: badgeSide, font: badgeFont, fill: badgeFill, text: badgeText)
        }
        spinner.isHidden = !showsSpinner
        if showsSpinner {
            spinnerWidth.constant = spinnerSide
            spinnerHeight.constant = spinnerSide
            spinner.color = spinnerColor
            spinner.toolTip = spinnerTooltip
        }
    }
}

/// Trailing status slot: spinner or badge, plus the hover-revealed close
/// button that occupies the same reserved space (AppKit port of
/// `SidebarWorkspaceTrailingStatusSlot`).
final class SidebarWorkspaceCellTrailingStatusSlotView: NSView {
    private let badge = SidebarWorkspaceCellUnreadBadgeView()
    private let spinner = GPUSpinnerNSView(frame: .zero)
    private let closeButton = SidebarWorkspaceCellButton()
    private lazy var slotWidth = widthAnchor.constraint(equalToConstant: 16)
    private lazy var slotHeight = heightAnchor.constraint(equalToConstant: 16)
    private lazy var spinnerWidth = spinner.widthAnchor.constraint(equalToConstant: 12)
    private lazy var spinnerHeight = spinner.heightAnchor.constraint(equalToConstant: 12)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)
        addSubview(spinner)
        addSubview(closeButton)
        NSLayoutConstraint.activate([
            slotWidth,
            slotHeight,
            badge.trailingAnchor.constraint(equalTo: trailingAnchor),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.trailingAnchor.constraint(equalTo: trailingAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinnerWidth,
            spinnerHeight,
            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            closeButton.topAnchor.constraint(equalTo: topAnchor),
            closeButton.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { nil }

    // swiftlint:disable:next function_parameter_count
    func update(
        showsSpinner: Bool,
        showsBadge: Bool,
        unreadCount: Int,
        badgeSide: CGFloat,
        width: CGFloat,
        height: CGFloat,
        badgeFont: NSFont,
        badgeFill: NSColor,
        badgeText: NSColor,
        spinnerColor: NSColor,
        spinnerTooltip: String,
        canCloseWorkspace: Bool,
        showsCloseButton: Bool,
        closeButtonTooltip: String,
        closeButtonColor: NSColor,
        closeButtonFontSize: CGFloat,
        closeAction: (() -> Void)?
    ) {
        slotWidth.constant = width
        slotHeight.constant = height
        let hidesStatusForClose = canCloseWorkspace && showsCloseButton

        spinner.isHidden = !showsSpinner
        spinner.alphaValue = hidesStatusForClose ? 0 : 1
        if showsSpinner {
            spinnerWidth.constant = badgeSide
            spinnerHeight.constant = badgeSide
            spinner.color = spinnerColor
            spinner.toolTip = spinnerTooltip
        }

        let showsBadgeNow = showsBadge && !showsSpinner
        badge.isHidden = !showsBadgeNow
        badge.alphaValue = hidesStatusForClose ? 0 : 1
        if showsBadgeNow {
            badge.update(count: unreadCount, side: badgeSide, font: badgeFont, fill: badgeFill, text: badgeText)
        }

        closeButton.isHidden = !canCloseWorkspace
        closeButton.alphaValue = showsCloseButton ? 1 : 0
        closeButton.isInteractionEnabled = showsCloseButton
        if canCloseWorkspace {
            closeButton.image = SidebarWorkspaceCellSymbols.image(
                "xmark",
                pointSize: closeButtonFontSize,
                weight: .medium
            )
            closeButton.contentTintColor = closeButtonColor
            closeButton.toolTip = showsCloseButton ? closeButtonTooltip : nil
            closeButton.onPress = closeAction
            closeButton.setAccessibilityElement(showsCloseButton)
        }
    }
}
