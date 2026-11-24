import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// One archived chat in the Priority view's Archived fold: its title, then its folder and how long ago it was
/// archived at the right, on one line in the quieter ink an archived workspace row uses. The pointer over the row
/// swaps that tag for Restore; a click opens the chat, and the right-click menu is the App's menu for the chat
/// (`SidebarContextTarget.priorityChat`), which offers Restore for an archived chat. Also the fold's Show More row
/// (`showMore`), which only takes a click.
final class SidebarArchivedChatRowView: NSView {
    private(set) var chat: SidebarArchivedChat?
    var onAction: ((SidebarPriorityAction) -> Void)?

    private let title = ChromeLabel(labelWithString: "")
    private let detail = ChromeLabel(labelWithString: "")
    private let restore = SidebarIconButton(symbol: "arrow.uturn.backward", label: Strings.priorityRestore)
    private var pointerHover: PointerHover?
    private var isHovered = false { didSet { if isHovered != oldValue { needsLayout = true; needsDisplay = true } } }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        title.lineBreakMode = .byTruncatingTail
        detail.lineBreakMode = .byTruncatingHead
        [title, detail, restore].forEach(addSubview)
        restore.isHidden = true
        restore.onPress = { [weak self] in
            guard let self, let chat = self.chat else { return }
            self.onAction?(.restore(chat.id))
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        pointerHover = PointerHover(self) { [weak self] hovering in self?.isHovered = hovering }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }
    nonisolated override var wantsUpdateLayer: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The row of `chat`, its archive age as of `now`.
    func configure(_ chat: SidebarArchivedChat, now: Date = Date()) {
        self.chat = chat
        title.stringValue = chat.title
        let age = chat.archivedAt.flatMap { SidebarPriorityRowView.elapsed(from: $0, to: now) }
        detail.stringValue = Self.tagText(project: chat.project, age: age)
        setAccessibilityLabel([chat.title, detail.stringValue.isEmpty ? nil : detail.stringValue].compactMap(\.self).joined(separator: ", "))
        needsLayout = true
        needsDisplay = true
    }

    /// The Show More row: `hidden` more archived chats wait past the page.
    func configureShowMore(hidden: Int) {
        chat = nil
        title.stringValue = Strings.showMore(hidden)
        detail.stringValue = ""
        setAccessibilityLabel(title.stringValue)
        needsLayout = true
        needsDisplay = true
    }

    /// "project · 2h", either part alone, or empty.
    static func tagText(project: String?, age: String?) -> String {
        [project, age].compactMap(\.self).joined(separator: " · ")
    }

    /// Every row of the fold (its header, a chat, Show More) is one sidebar row high.
    static var height: CGFloat { SidebarDensityTokens.rowHeight }

    override func layout() {
        super.layout()
        let b = bounds, inset = SidebarStyle.horizontalInset
        title.font = chat == nil ? SidebarStyle.headerFont : SidebarStyle.titleFont
        detail.font = SidebarStyle.subtitleFont
        let lineHeight = ceil(SidebarStyle.titleFont.boundingRectForFont.height)
        let y = (b.height - lineHeight) / 2
        let textInset = SidebarStyle.leadingTextX(leading: inset)
        var trailing = b.width - inset
        let showsRestore = isHovered && chat != nil
        restore.isHidden = !showsRestore
        detail.isHidden = showsRestore || detail.stringValue.isEmpty
        if showsRestore {
            restore.frame = NSRect(x: trailing - lineHeight, y: y, width: lineHeight, height: lineHeight)
            trailing = restore.frame.minX - Metrics.space1
        } else if !detail.isHidden {
            let width = min(detail.naturalSize.width, max(0, trailing - textInset) * 0.45)
            detail.frame = NSRect(x: trailing - width, y: y, width: width, height: lineHeight)
            trailing = detail.frame.minX - Metrics.space2
        }
        title.frame = NSRect(x: textInset, y: y, width: max(0, trailing - textInset), height: lineHeight)
    }

    override func updateLayer() {
        performWithTheme {
            title.textColor = Palette.textSecondary
            detail.textColor = Palette.textTertiary
            if let layer {
                layer.cornerRadius = SidebarStyle.rowCornerRadius
                ChromeHover.paint(layer, isHovered ? Palette.hoverFill : nil, animated: window != nil)
            }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        guard bounds.contains(local) else { return nil }
        if !restore.isHidden, restore.frame.contains(local) { return restore.hitTest(convert(local, to: restore)) ?? restore }
        return self
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        press()
    }

    override func mouseDown(with event: NSEvent) {}

    private func press() {
        if let chat { onAction?(.openArchived(chat.id)) } else { onAction?(.showMoreArchived) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let chat else { return nil }
        let sidebar = sequence(first: superview, next: { $0?.superview }).lazy.compactMap { $0 as? SidebarView }.first
        return sidebar?.contextMenuProvider?(.priorityChat(chat.id))
    }

    override func accessibilityPerformPress() -> Bool {
        press()
        return true
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard let chat else { return super.accessibilityCustomActions() }
        return (super.accessibilityCustomActions() ?? []) + [
            NSAccessibilityCustomAction(name: Strings.priorityRestore) { [weak self] in
                self?.onAction?(.restore(chat.id))
                return self != nil
            },
        ]
    }
}
