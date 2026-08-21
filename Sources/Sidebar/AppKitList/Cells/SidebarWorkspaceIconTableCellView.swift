import AppKit
import CmuxFoundation
import SwiftUI

/// Icon-rail presentation of one workspace or group-header row: a single
/// rounded avatar (monogram tinted by the workspace color, or the group's
/// symbol) with a selection ring and an unread dot. Every textual detail
/// moves to the row's hover card. Selection, click dispatch, and drag
/// handling stay controller-owned, and the context menu reuses the regular
/// row's shared builder so both presentations expose identical actions.
@MainActor
final class SidebarWorkspaceIconTableCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("SidebarWorkspaceIconRowCell")
    static let rowHeight: CGFloat = 36

    private static let avatarSide: CGFloat = 28
    private static let avatarCornerRadius: CGFloat = 8
    private static let selectionRingWidth: CGFloat = 2

    private let avatarView = NSView()
    private let letterField = NSTextField(labelWithString: "")
    private let symbolView = NSImageView()
    private let unreadDot = NSView()

    private var workspaceActions: SidebarAppKitRowActions?
    private var groupActions: SidebarGroupHeaderRowActions?
    private var contextMenuDidOpen: (() -> Void)?
    private var contextMenuDidClose: (() -> Void)?
    private var isDark = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
        wantsLayer = true

        avatarView.wantsLayer = true
        avatarView.layer?.cornerRadius = Self.avatarCornerRadius
        avatarView.layer?.cornerCurve = .continuous
        addSubview(avatarView)

        letterField.alignment = .center
        letterField.lineBreakMode = .byClipping
        avatarView.addSubview(letterField)

        symbolView.imageScaling = .scaleProportionallyDown
        avatarView.addSubview(symbolView)

        unreadDot.wantsLayer = true
        unreadDot.layer?.cornerRadius = 4
        unreadDot.layer?.borderWidth = 1.5
        addSubview(unreadDot)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unsupported") }

    // MARK: Configure

    func configure(
        workspaceModel model: SidebarWorkspaceRowModel,
        actions: SidebarAppKitRowActions?,
        contextMenuDidOpen: @escaping () -> Void,
        contextMenuDidClose: @escaping () -> Void
    ) {
        workspaceActions = actions
        groupActions = nil
        self.contextMenuDidOpen = contextMenuDidOpen
        self.contextMenuDidClose = contextMenuDidClose
        isDark = model.colorSchemeIsDark
        toolTip = model.snapshot.title

        applyAvatar(
            letter: Self.avatarLetter(for: model.snapshot.title),
            symbolName: nil,
            tintHex: model.snapshot.customColorHex,
            isSelected: model.isActive,
            isMultiSelected: model.isMultiSelected,
            selectionColorHex: model.settings.selectionColorHex
        )
        applyUnread(count: model.unreadCount)
        setAccessibilityLabel(model.snapshot.title)
        needsLayout = true
    }

    func configure(
        groupModel model: SidebarGroupHeaderRowModel,
        actions: SidebarGroupHeaderRowActions?
    ) {
        workspaceActions = nil
        groupActions = actions
        contextMenuDidOpen = nil
        contextMenuDidClose = nil
        isDark = model.colorSchemeIsDark
        toolTip = model.name

        applyAvatar(
            letter: nil,
            symbolName: model.iconSymbol,
            tintHex: model.tintHex,
            isSelected: model.isAnchorActive,
            isMultiSelected: model.isMultiSelected,
            selectionColorHex: nil
        )
        applyUnread(count: model.anchorUnreadCount)
        setAccessibilityLabel(model.name)
        needsLayout = true
    }

    private func applyAvatar(
        letter: String?,
        symbolName: String?,
        tintHex: String?,
        isSelected: Bool,
        isMultiSelected: Bool,
        selectionColorHex: String?
    ) {
        let scheme: ColorScheme = isDark ? .dark : .light
        let tint = tintHex.flatMap {
            WorkspaceTabColorSettings.displayNSColor(
                hex: $0,
                colorScheme: scheme,
                forceBright: false
            )
        }

        let baseFill = tint?.withAlphaComponent(isSelected ? 0.42 : 0.26)
            ?? NSColor.secondaryLabelColor.withAlphaComponent(isSelected ? 0.26 : 0.14)
        avatarView.layer?.backgroundColor = baseFill.cgColor

        // Selection is a ring, not a second box behind the avatar: one shape
        // stays the row's identity in both states.
        if isSelected || isMultiSelected {
            let ringColor = sidebarSelectedRowBackgroundNSColor(
                for: scheme,
                sidebarSelectionColorHex: selectionColorHex
            )
            avatarView.layer?.borderWidth = Self.selectionRingWidth
            avatarView.layer?.borderColor = ringColor
                .withAlphaComponent(isSelected ? 1 : 0.55)
                .cgColor
        } else {
            avatarView.layer?.borderWidth = 0
            avatarView.layer?.borderColor = nil
        }

        if let symbolName, let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: nil
        ) {
            symbolView.image = image.withSymbolConfiguration(
                .init(pointSize: 12, weight: .semibold)
            )
            symbolView.contentTintColor = tint ?? .secondaryLabelColor
            symbolView.isHidden = false
            letterField.isHidden = true
        } else {
            letterField.stringValue = letter ?? ""
            letterField.font = Self.monogramFont
            letterField.textColor = .labelColor
            letterField.isHidden = false
            symbolView.isHidden = true
        }
    }

    /// Rounded-design monogram so the letter reads as an identity mark, not
    /// stray list text.
    private static let monogramFont: NSFont = {
        let base = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded),
              let rounded = NSFont(descriptor: descriptor, size: 12.5)
        else { return base }
        return rounded
    }()

    private func applyUnread(count: Int) {
        unreadDot.isHidden = count <= 0
        unreadDot.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        unreadDot.layer?.borderColor = (
            isDark ? NSColor.black : NSColor.white
        ).withAlphaComponent(0.85).cgColor
    }

    private static func avatarLetter(for title: String) -> String {
        guard let first = title.trimmingCharacters(in: .whitespacesAndNewlines).first else {
            return "•"
        }
        return String(first).uppercased()
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let midX = bounds.midX
        let midY = bounds.midY
        avatarView.frame = NSRect(
            x: midX - Self.avatarSide / 2,
            y: midY - Self.avatarSide / 2,
            width: Self.avatarSide,
            height: Self.avatarSide
        )
        letterField.frame = avatarView.bounds.insetBy(dx: 0, dy: 5)
        symbolView.frame = avatarView.bounds
        unreadDot.frame = NSRect(
            x: avatarView.frame.maxX - 4,
            y: avatarView.frame.maxY - 4,
            width: 8,
            height: 8
        )
    }

    // MARK: Menu

    override func menu(for event: NSEvent) -> NSMenu? {
        if let workspaceActions {
            let didOpen = contextMenuDidOpen
            let didClose = contextMenuDidClose
            return workspaceActions.commands.makeContextMenu(
                onOpen: { didOpen?() },
                onClose: { didClose?() }
            )
        }
        return super.menu(for: event)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        workspaceActions = nil
        groupActions = nil
        contextMenuDidOpen = nil
        contextMenuDidClose = nil
        toolTip = nil
    }
}
