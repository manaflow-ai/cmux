import AppKit
import CmuxFoundation
import MessagesLabSidebar

/// Home's conversation list as the window's left sidebar shows it while Home
/// is selected: MessagesLab's list (search, then Messages' 72 pt rows with a
/// 40 pt avatar, name, two-line preview and time; pinned tiles only for
/// conversations the user pinned) under the pinned Chief row.
///
/// It draws no background: it sits on the sidebar's own material, so the
/// sidebar stays one surface. MessagesLab reserves a 52 pt titlebar strip
/// above its search field; the sidebar already has its titlebar and the Chief
/// row there, so this view clips that strip away and the search field starts
/// at the top. It owns no data: ``ChiefHomeView`` shows entries after every
/// change and answers the choices.
@MainActor
final class ChiefConversationListView: NSView {
    /// MessagesLab's search field starts this far down (its titlebar strip).
    static let messagesTitlebarStrip: CGFloat = 52

    let list = CmuxSidebarView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        list.setAccessibilityLabel(ChiefStrings.conversationsList)
        list.scrollView.scrollerStyle = .overlay
        addSubview(list)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

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
        let frame = CGRect(x: 0, y: -strip, width: bounds.width, height: bounds.height + strip)
        if list.frame != frame { list.frame = frame }
    }
}
