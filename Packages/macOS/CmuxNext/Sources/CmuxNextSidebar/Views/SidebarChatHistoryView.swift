public import AppKit
import CmuxNextDesign

/// The session tree's chat history blocks in the list (`SidebarChatHistoryState`): Pinned above the
/// workspaces, Earlier under them, each at the place the layout leaves for it
/// (`SidebarLayout.pinnedChatsY`, `earlierChatsY`). They scroll with the rows and move with them.
@MainActor
final class SidebarChatHistoryViews {
    let pinned = SidebarChatHistoryView(part: .pinned)
    let earlier = SidebarChatHistoryView(part: .earlier)

    var all: [SidebarChatHistoryView] { [pinned, earlier] }

    /// Shows `state` at `layout`'s places in `list`. When `animated`, returns each shown block with its frame for the
    /// caller to move on the rows' render-server spring in the rows' own transaction (`RowMotion.animate`), an
    /// unmoved block too (with movement off its earlier spring comes off); without motion the blocks land here.
    @discardableResult
    func place(_ layout: SidebarLayout, state: SidebarChatHistoryState?, metrics: SidebarLayoutMetrics, in list: SidebarListView,
               animated: Bool) -> [(NSView, NSRect)] {
        // As wide as a row (`SidebarListView.frame(for:)`), following the list's width.
        func frame(_ y: CGFloat, _ height: CGFloat) -> NSRect {
            NSRect(x: list.inset, y: y, width: max(0, list.bounds.width - list.inset * 2), height: height)
        }
        let frames: [(SidebarChatHistoryView, NSRect?)] = [
            (pinned, layout.pinnedChatsY.map { frame($0, state?.pinnedHeight(metrics) ?? 0) }),
            (earlier, layout.earlierChatsY.map { frame($0, state?.earlierHeight(metrics) ?? 0) })
        ]
        var moves: [(NSView, NSRect)] = []
        for (view, frame) in frames {
            guard let state, let frame else {
                view.isHidden = true
                continue
            }
            if view.superview !== list {
                view.autoresizingMask = [.width]
                list.addSubview(view, positioned: .above, relativeTo: list.decorations)
            }
            view.show(state, metrics: metrics)
            if view.isHidden || !animated {
                // In one step: a spring an earlier move left on the block comes off with it.
                SidebarDragSpring.stop([view])
                Motion.withoutAnimation { view.frame = frame }
                view.isHidden = false
            } else {
                moves.append((view, frame))
            }
        }
        return moves
    }

    /// Moves both blocks with the rows and the scroll offset (the list's viewport anchor step).
    func shift(by dy: CGFloat) {
        Motion.withoutAnimation { for view in all where !view.isHidden { view.frame.origin.y += dy } }
    }
}

/// One history block: a quiet header (Pinned, or Earlier, which folds), then one compact row per
/// chat (its title and a faint age), and for Earlier a Show More row. A row resumes its chat on a
/// click and pins or unpins it from its right-click menu. Rows are made for the shown page only.
final class SidebarChatHistoryView: NSView {
    enum Part { case pinned, earlier }

    let part: Part
    let header = SidebarChatHistoryHeader()
    private(set) var rows: [SidebarChatHistoryRow] = []
    let more = SidebarChatHistoryRow()
    private var chats: [SidebarHistoryChat] = []
    private var showsMore = false
    private var folded = false
    private var metrics = SidebarLayoutMetrics.standard
    /// Where the history's clicks go (tests swap in their own).
    var history: SidebarChatHistory = .shared

    init(part: Part) {
        self.part = part
        super.init(frame: .zero)
        wantsLayer = true
        isHidden = true
        addSubview(header)
        addSubview(more)
        header.onClick = { [weak self] in
            guard let self, self.part == .earlier else { return }
            self.history.toggleEarlier()
        }
        more.onClick = { [weak self] in self?.history.showMore() }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    /// A click between the rows starts no press in the list (a double-click there makes no workspace).
    override func mouseDown(with event: NSEvent) {}

    func show(_ state: SidebarChatHistoryState, metrics: SidebarLayoutMetrics) {
        let chats = part == .pinned ? state.pinned : state.earlier
        let showsMore = part == .earlier && state.hasMore && !state.earlierFolded
        let folded = part == .earlier && state.earlierFolded
        guard chats != self.chats || showsMore != self.showsMore || folded != self.folded || metrics != self.metrics else { return }
        (self.chats, self.showsMore, self.folded, self.metrics) = (chats, showsMore, folded, metrics)
        let title = part == .pinned ? Strings.pinned : Strings.chatHistoryEarlier
        header.configure(title: title, foldable: part == .earlier, folded: folded)
        setAccessibilityLabel(title)
        while rows.count < chats.count {
            let row = SidebarChatHistoryRow()
            addSubview(row)
            rows.append(row)
        }
        if rows.count > chats.count {
            rows[chats.count...].forEach { $0.removeFromSuperview() }
            rows.removeLast(rows.count - chats.count)
        }
        let now = Date()
        for (row, chat) in zip(rows, chats) {
            let key = chat.id
            row.configure(title: chat.title, meta: SidebarChatsDesign.age(from: chat.updatedAt, to: now),
                          harness: chat.harness, quiet: part == .earlier)
            row.onClick = { [weak self] in self?.history.open(key) }
            row.makeMenu = { [weak self] in
                guard let self, let menu = self.history.makeMenu?(key) else { return nil }
                // The registry's Pin or Unpin Chat row, named for what it does to this chat.
                let title = self.history.isPinned(key) ? Strings.chatHistoryUnpin : Strings.chatHistoryPin
                if let item = menu.items.first(where: { !$0.isSeparatorItem }) { item.title = title }
                return menu
            }
        }
        more.configure(title: Strings.chatHistoryShowMore, meta: nil, harness: nil, quiet: true)
        more.isHidden = !showsMore
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let m = metrics
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: m.sectionHeaderHeight)
        var y = m.sectionHeaderHeight
        for row in rows {
            row.isHidden = folded
            row.frame = NSRect(x: 0, y: y, width: bounds.width, height: m.rowHeight)
            if !folded { y += m.rowHeight + m.rowSpacing }
        }
        more.frame = NSRect(x: 0, y: y, width: bounds.width, height: m.rowHeight)
    }
}
