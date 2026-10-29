import AppKit
import CmuxFoundation
import MessagesLabSidebar

/// MessagesLab's conversation list and compose action inside a Chief pane.
/// A clipped content host removes the vendor's window-titlebar strip while
/// keeping search and rows below this pane's navigation controls.
@MainActor
final class ChiefConversationListView: NSView {
    private final class ListClipView: NSView {
        override var isFlipped: Bool { true }
    }
    /// MessagesLab's search field starts this far down (its titlebar strip).
    static let messagesTitlebarStrip: CGFloat = 52

    let list = CmuxSidebarView()
    private let content = ListClipView()
    private let composeButton = NSButton()
    private let titleLabel = NSTextField(labelWithString: ChiefStrings.conversationsList)
    var onNewConversation: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        list.setAccessibilityLabel(ChiefStrings.conversationsList)
        list.setAccessibilityIdentifier("ChiefConversationList")
        list.scrollView.scrollerStyle = .overlay
        content.clipsToBounds = true
        content.addSubview(list)
        addSubview(content)
        composeButton.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: nil)
        composeButton.imagePosition = .imageOnly
        composeButton.isBordered = false
        composeButton.target = self
        composeButton.action = #selector(compose)
        composeButton.toolTip = ChiefStrings.newConversation
        composeButton.setAccessibilityLabel(ChiefStrings.newConversation)
        composeButton.setAccessibilityIdentifier("ChiefNewConversation")
        addSubview(composeButton)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    @objc private func compose() { onNewConversation?() }

    /// The sidebar's content appearance and the cmux accent: the unread dot and
    /// the selected row take the accent, as a selected workspace row does.
    func apply(isDark: Bool, accent: NSColor) {
        appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        list.unreadColor = accent
        list.selectionColor = accent
    }

    override func layout() {
        super.layout()
        let strip = Self.messagesTitlebarStrip
        let header: CGFloat = min(40, bounds.height)
        content.frame = CGRect(x: 0, y: header, width: bounds.width, height: max(0, bounds.height - header))
        titleLabel.frame = CGRect(x: 12, y: 12, width: max(0, bounds.width - 56), height: 18)
        composeButton.frame = CGRect(x: max(0, bounds.width - 36), y: 6, width: 28, height: 28)
        let frame = CGRect(x: 0, y: -strip, width: content.bounds.width, height: content.bounds.height + strip)
        if list.frame != frame { list.frame = frame }
    }
}
