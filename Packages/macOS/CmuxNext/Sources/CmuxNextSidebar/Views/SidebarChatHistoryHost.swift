import AppKit
import CmuxNextDesign
import CmuxNextPages
import Foundation

/// The session tree's chat history blocks in the list (`SidebarChatHistoryState`): Pinned above the
/// workspaces, Earlier under them, each at the place the layout leaves for it
/// (`SidebarLayout.pinnedChatsY`, `earlierChatsY`). They scroll with the rows and move with them. Each block
/// is the React page webviews/src/pages/sidebar-chats in a ``SidebarChatHistoryHost``.
@MainActor
final class SidebarChatHistoryViews {
    let pinned: SidebarChatHistoryHost
    let earlier: SidebarChatHistoryHost

    init(makePage: @escaping SidebarChatHistoryHost.MakePage = SidebarChatHistoryHost.makePage) {
        pinned = SidebarChatHistoryHost(part: .pinned, makePage: makePage)
        earlier = SidebarChatHistoryHost(part: .earlier, makePage: makePage)
    }

    var all: [SidebarChatHistoryHost] { [pinned, earlier] }

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
        let frames: [(SidebarChatHistoryHost, NSRect?)] = [
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
            view.show(state, metrics: metrics, width: frame.width)
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

/// One chat history block in the list: the transparent page (``PageDescriptor/sidebarChats``) the block draws in,
/// and the native glue around it. It pushes the block (``SidebarChatHistoryBlock``) when the state, the grid or an
/// age changes, and runs the page's checked calls through ``SidebarChatHistory``, the same paths the AppKit rows
/// ran: a click opens (resumes) the chat, Earlier's header folds it, Show More lists the next page, and a right click
/// shows the registry's Pin or Unpin Chat menu. The page is made the first time the block shows (the session tree on),
/// never takes the keys, passes scrolls to the list, and shows once it reported drawing a block.
final class SidebarChatHistoryHost: NSView {
    enum Part: String { case pinned, earlier }
    typealias MakePage = @MainActor (SidebarChatHistoryProvider) -> PageWebView?

    let part: Part
    let provider = SidebarChatHistoryProvider()
    /// Where the block's clicks go (tests swap in their own).
    var history: SidebarChatHistory = .shared
    private let makePage: MakePage
    private(set) var page: PageWebView?
    /// The page's last `ready`: the revision it drew and its height in CSS px (one px is one point here).
    private(set) var drawn: (revision: Int, height: Double)?
    /// Shows a menu at a page point (tests record it instead).
    var presentMenu: @MainActor (NSMenu, CGPoint, PageWebView) async -> Void = { menu, point, page in
        await page.presentMenu(menu, atPagePoint: point)
    }

    init(part: Part, makePage: @escaping MakePage = SidebarChatHistoryHost.makePage) {
        self.part = part
        self.makePage = makePage
        super.init(frame: .zero)
        wantsLayer = true
        isHidden = true
        // The page's document names the block and its rows for VoiceOver.
        setAccessibilityElement(false)
        provider.onCall = { [weak self] call in await self?.handle(call) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    /// A press that reaches the host itself (outside the page) starts no press or marquee in the list under it.
    override func mouseDown(with event: NSEvent) {}

    /// The page in WebKit (it sits inside the list's scroll view, transparent over the sidebar's backdrop), with the
    /// first click, kept loaded across web updates (the block is always in sight).
    static let engineOptions = PageEngineOptions(requiresWebKit: .transparentOverlay, acceptsFirstMouse: true, keepsLoadedWeb: true)

    static func makePage(_ provider: SidebarChatHistoryProvider) -> PageWebView? {
        let page = PageWebView(descriptor: .sidebarChats, routes: [PageRoute(prefix: SidebarChatHistoryProvider.prefix, provider: provider)],
                               options: engineOptions)
        page?.refusesKeyFocus = true
        page?.followsUIScale = false
        page?.passesScrollWheel = true
        return page
    }

    /// Shows `state`'s block at `metrics` for a block `width` points wide.
    func show(_ state: SidebarChatHistoryState, metrics: SidebarLayoutMetrics, width: CGFloat) {
        let block = performWithTheme { SidebarChatHistoryBlock(part: part, state: state, metrics: metrics, width: width, now: Date()) }
        provider.push(block)
        guard page == nil, let made = makePage(provider) else { return }
        page = made
        // Nothing shows until the page drew a block (no empty or unstyled first frame in the gap).
        made.alphaValue = 0
        made.frame = bounds
        made.autoresizingMask = [.width, .height]
        addSubview(made)
    }

    func handle(_ call: SidebarChatHistoryProvider.Call) async {
        switch call {
        case let .open(chat):
            history.open(chat)
        case .fold:
            history.toggleEarlier()
        case .more:
            // The Loading row asks for no page.
            guard provider.block?.tail == .more else { return }
            history.showMore()
        case let .menu(chat, point):
            guard let page, let menu = contextMenu(for: chat) else { return }
            await presentMenu(menu, point, page)
        case let .ready(revision, height):
            drawn = (revision, height)
            page?.alphaValue = 1
        }
    }

    /// `chat`'s right-click menu: the registry's Pin or Unpin Chat row, named for what it does to this chat; nil
    /// without one or with no rows.
    func contextMenu(for chat: String) -> NSMenu? {
        guard let menu = history.makeMenu?(chat), !menu.items.isEmpty else { return nil }
        let title = history.isPinned(chat) ? Strings.chatHistoryUnpin : Strings.chatHistoryPin
        if let item = menu.items.first(where: { !$0.isSeparatorItem }) { item.title = title }
        return menu
    }
}
