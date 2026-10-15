import AppKit
import CmuxFoundation
import MessagesLabSidebar

/// Home's left column (cmux-next `HomeSidebarView`): MessagesLab's
/// conversation list (search, the pinned grid, the rows) under a 52 pt strip
/// that holds the compose button, over a translucent scrim of the terminal
/// background. It owns no data: ``ChiefHomeView`` shows entries after every
/// change and answers the choices.
@MainActor
final class ChiefConversationListView: NSView {
    /// MessagesLab's search field starts this far down.
    static let stripHeight: CGFloat = 52

    let list = CmuxSidebarView()
    private let strip = ChiefWindowDragStrip()
    private let compose = NSButton()
    /// The compose button: a new conversation with a new Chief.
    var onNewConversation: () -> Void = {}

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        list.frame = bounds
        list.autoresizingMask = [.width, .height]
        list.setAccessibilityLabel(ChiefStrings.conversationsList)
        addSubview(list)
        addSubview(strip)
        compose.bezelStyle = .accessoryBarAction
        compose.isBordered = false
        compose.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: ChiefStrings.newConversation)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular))
        compose.setAccessibilityLabel(ChiefStrings.newConversation)
        compose.toolTip = ChiefStrings.newConversation
        compose.target = self
        compose.action = #selector(newConversation)
        addSubview(compose)
        list.scrollView.scrollerStyle = .overlay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    var minimumWidth: CGFloat { list.minimumWidth }
    var preferredWidth: CGFloat { list.preferredWidth }

    func apply(_ theme: ChiefTheme) {
        // The scrim lets the window's own background (and its opacity) show through, like the transcript.
        layer?.backgroundColor = theme.mix(theme.isDark ? 0.04 : 0.025).withAlphaComponent(theme.isDark ? 0.55 : 0.5).cgColor
        // The unread dot is the app's accent; only sent bubbles are iMessage blue.
        list.unreadColor = (AppDelegate.shared?.accentColor ?? CmuxAccentColor()).nsColor(isDark: theme.isDark)
        compose.contentTintColor = theme.textSecondary
        appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
    }

    override func layout() {
        super.layout()
        // Not flipped: the strip is the top `stripHeight` points.
        let side: CGFloat = 28
        strip.frame = NSRect(x: 0, y: bounds.height - Self.stripHeight, width: max(0, bounds.width - side - 16),
                             height: Self.stripHeight)
        compose.frame = NSRect(x: bounds.width - side - 12, y: bounds.height - 26 - side / 2, width: side, height: side)
    }

    @objc private func newConversation() { onNewConversation() }
}

/// Empty header space that drags the window, as on Messages' sidebar toolbar.
final class ChiefWindowDragStrip: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}
