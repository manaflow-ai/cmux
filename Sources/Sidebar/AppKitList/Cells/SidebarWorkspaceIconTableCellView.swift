import AppKit
import CmuxFoundation
import SwiftUI

/// Icon-rail presentation of one workspace or group-header row: a single
/// centered glyph with selection paint and an unread dot. Every textual
/// detail moves to the row's hover card. Selection, click dispatch, and drag
/// handling stay controller-owned, and the context menu reuses the regular
/// row's shared builder so both presentations expose identical actions.
@MainActor
final class SidebarWorkspaceIconTableCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("SidebarWorkspaceIconRowCell")
    static let rowHeight: CGFloat = 36

    private static let avatarSide: CGFloat = 26
    private static let selectionSide: CGFloat = 32

    private let selectionBackground = NSView()
    private let avatarBackground = NSView()
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

        selectionBackground.wantsLayer = true
        selectionBackground.layer?.cornerRadius = 6
        selectionBackground.layer?.cornerCurve = .continuous
        addSubview(selectionBackground)

        avatarBackground.wantsLayer = true
        avatarBackground.layer?.cornerRadius = 7
        avatarBackground.layer?.cornerCurve = .continuous
        addSubview(avatarBackground)

        letterField.alignment = .center
        letterField.lineBreakMode = .byClipping
        avatarBackground.addSubview(letterField)

        symbolView.imageScaling = .scaleProportionallyDown
        avatarBackground.addSubview(symbolView)

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

        applySelection(
            isActive: model.isActive || model.isMultiSelected,
            selectionColorHex: model.settings.selectionColorHex,
            dimmed: model.isMultiSelected && !model.isActive
        )
        applyAvatar(
            letter: Self.avatarLetter(for: model.snapshot.title),
            symbolName: nil,
            tintHex: model.snapshot.customColorHex
        )
        applyUnread(count: model.unreadCount)
        accessibilityLabelOverride = model.snapshot.title
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

        applySelection(
            isActive: model.isAnchorActive || model.isMultiSelected,
            selectionColorHex: nil,
            dimmed: model.isMultiSelected && !model.isAnchorActive
        )
        applyAvatar(
            letter: nil,
            symbolName: model.iconSymbol,
            tintHex: model.tintHex
        )
        applyUnread(count: model.anchorUnreadCount)
        accessibilityLabelOverride = model.name
        needsLayout = true
    }

    private var accessibilityLabelOverride: String = "" {
        didSet { setAccessibilityLabel(accessibilityLabelOverride) }
    }

    private func applySelection(isActive: Bool, selectionColorHex: String?, dimmed: Bool) {
        let scheme: ColorScheme = isDark ? .dark : .light
        if isActive {
            let color = sidebarSelectedRowBackgroundNSColor(
                for: scheme,
                sidebarSelectionColorHex: selectionColorHex
            )
            selectionBackground.layer?.backgroundColor =
                color.withAlphaComponent(dimmed ? 0.45 : 1).cgColor
            selectionBackground.isHidden = false
        } else {
            selectionBackground.isHidden = true
        }
    }

    private func applyAvatar(letter: String?, symbolName: String?, tintHex: String?) {
        let scheme: ColorScheme = isDark ? .dark : .light
        let tint = tintHex.flatMap {
            WorkspaceTabColorSettings.displayNSColor(
                hex: $0,
                colorScheme: scheme,
                forceBright: false
            )
        }
        avatarBackground.layer?.backgroundColor = (
            tint?.withAlphaComponent(0.35)
                ?? NSColor.secondaryLabelColor.withAlphaComponent(0.16)
        ).cgColor

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
            letterField.font = .systemFont(ofSize: 12.5, weight: .semibold)
            letterField.textColor = tint == nil ? .labelColor : .labelColor
            letterField.isHidden = false
            symbolView.isHidden = true
        }
    }

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
        selectionBackground.frame = NSRect(
            x: midX - Self.selectionSide / 2,
            y: midY - Self.selectionSide / 2,
            width: Self.selectionSide,
            height: Self.selectionSide
        )
        avatarBackground.frame = NSRect(
            x: midX - Self.avatarSide / 2,
            y: midY - Self.avatarSide / 2,
            width: Self.avatarSide,
            height: Self.avatarSide
        )
        letterField.frame = avatarBackground.bounds.insetBy(dx: 0, dy: 4)
        symbolView.frame = avatarBackground.bounds
        unreadDot.frame = NSRect(
            x: avatarBackground.frame.maxX - 5,
            y: avatarBackground.frame.maxY - 5,
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
