public import AppKit
import CmuxNextDesign
import CmuxNextHomeModel
import CmuxNextWakeups
import Observation

/// The Home page's two columns with a real divider: the resize cursor over a
/// wide grab area, the sidebar between its minimum and half the window, a
/// double-click back to the standard width, and the width kept per window
/// (`HomeSidebarWidth`). The docked column model takes this width over when
/// the daemon owns the column. While the list shows avatars only, its compose
/// button shows at the chat's top-left instead (`HomeChatColumnView`). An avatar-only list that
/// holds one conversation takes no column at all (`foldsLoneConversation`).
///
/// The list is folded until the person shows it with the chat's Chats button (``showsList``): the Chief replaces
/// Home (the person, 2026-11-20), so the Chief's chat fills the page and the other chats are one click away.
@MainActor
public final class HomeSidebarSplitView: NSSplitView, NSSplitViewDelegate {
    /// The window's key for its saved width (resolved on use: the window's
    /// id changes once when it adopts a restored record).
    public var windowKey: () -> String = { "" }
    public let widths: HomeSidebarWidth
    /// Half the grab area on each side of the 1 pt divider.
    public static let grab: CGFloat = 4
    var placed = false
    /// This view moves the divider itself (a clamp, a reset): not the user's width to keep.
    private var placing = false
    /// The list's own limits (MessagesLab's `minimumWidth`, `preferredWidth`).
    public let minimum: CGFloat
    public let standard: CGFloat
    /// The chat column: `content` with the list's compose over its top-left while the list is narrow.
    let chatColumn: HomeChatColumnView
    /// The New Message page is on screen: the chat's compose button stays hidden (it would sit
    /// over To:, and the person is composing already).
    public var composing = false {
        didSet { if composing != oldValue { updateChatCompose() } }
    }
    let list: HomeSidebarView
    /// The list's slide in or out while it runs (``HomeSidebarSlide``, HomeSidebarSplitView+Slide.swift).
    var slide: HomeSidebarSlide?
    /// The list's width for the running slide (it slides at this width, never squeezed).
    var slideWidth: CGFloat = 0
    /// The running slide's frames, from the window's FrameScheduler.
    /// Out of sight (the window hidden or closed) it lands at once.
    lazy var slideClient = FrameClient(owner: "Home.listSlide", scheduler: { [weak self] in self.map(FrameScheduler.forView) ?? .app },
                                       settle: { [weak self] in self?.endSlide() }, dropped: { [weak self] in self?.endSlide() }) { [weak self] tick in
        self?.slideFrame(tick) ?? false
    }
    /// Debug Settings (`HomeTunables.loneConversationRail`); tests give their own store.
    var tunables = TunableStore.shared {
        didSet { followLoneConversationTunable() }
    }

    public init(sidebar: HomeSidebarView, content: NSView, widths: HomeSidebarWidth = HomeSidebarWidth()) {
        self.widths = widths
        list = sidebar
        minimum = sidebar.minimumWidth
        standard = sidebar.preferredWidth
        chatColumn = HomeChatColumnView(content: content, compose: sidebar.chatCompose, chats: HomeChatListButton())
        super.init(frame: .zero)
        chatColumn.chats.target = self
        chatColumn.chats.action = #selector(toggleList)
        chatColumn.chats.isOn = widths.listShown
        isVertical = true
        dividerStyle = .thin
        addArrangedSubview(sidebar)
        addArrangedSubview(chatColumn)
        setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        delegate = self
        wantsLayer = true
        setAccessibilityIdentifier("cmux.home.split")
        sidebar.onContentChange = { [weak self] in self?.needsLayout = true }
        followLoneConversationTunable()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    /// Whether the conversation list shows beside the chat (the Chats button): kept on this Mac
    /// (``HomeSidebarWidth/listShown``); off by default, so the Chief's chat fills the page.
    public var showsList: Bool {
        get { widths.listShown }
        set {
            guard newValue != widths.listShown else { return }
            // Where the list is now (mid-slide too), before the choice changes what layout places.
            let shownNow = slide?.reveal ?? sidebarWidth
            widths.listShown = newValue
            chatColumn.chats.isOn = newValue
            if let spring = slideSpring(open: newValue) {
                slideList(from: shownNow, open: newValue, spring: spring)
            } else {
                // A slide cut short lands where the choice is now.
                endSlide()
                needsLayout = true
                layoutSubtreeIfNeeded()
            }
        }
    }

    /// A slide running when the page leaves its window lands there.
    override public func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { endSlide() }
    }

    /// The Chats button: shows or folds the conversation list.
    @objc private func toggleList() { showsList.toggle() }

    /// Zero while the list is folded (a hidden subview keeps its last frame).
    public var sidebarWidth: CGFloat { list.isHidden ? 0 : list.frame.width }

    /// The divider in window points from the content view's top-left (as
    /// `debug.mouse` takes them), nil before the view is in a window.
    public var dividerFrameInWindow: NSRect? {
        guard let window else { return nil }
        let base = convert(dividerRect, to: nil)
        let height = window.contentView?.bounds.height ?? window.frame.height
        return NSRect(x: base.minX, y: height - base.maxY, width: base.width, height: base.height)
    }

    private var dividerRect: NSRect {
        NSRect(x: sidebarWidth, y: 0, width: dividerThickness, height: bounds.height)
    }

    /// The width to show now: the saved one (else the standard), clamped to this window.
    var wantedWidth: CGFloat {
        clamp(widths.width(window: windowKey()) ?? standard)
    }

    private func clamp(_ width: CGFloat) -> CGFloat {
        HomeSidebarWidth.clamp(width, window: bounds.width - dividerThickness, minimum: minimum)
    }

    /// The transcript's width now (tests and `debug.home page`).
    public var transcriptWidth: CGFloat { arrangedSubviews.last?.frame.width ?? 0 }

    /// No divider line and no hover or drag band (the user, 2026-11-23: a straight band crossed the
    /// panel's rounded corners; "maybe we just don't show the hovered line"): the list's panel rim
    /// is the edge, as in Messages (macOS 26). The grab area and the resize cursor stay.
    override public var dividerColor: NSColor { .clear }

    override public func layout() {
        super.layout()
        guard bounds.width > 0 else { return }
        // The slide places both columns itself each frame (a resize mid-slide keeps its place too).
        if slide != nil { return placeSlideFrame() }
        // The page may have moved under or out from under the traffic lights (the window's sidebar).
        list.updateWindowControlsAvoidance()
        if foldLoneConversation() { return }
        // One rule on every size change (live resize, split drag, fullscreen, a dock that
        // shrank): the list shows the saved width as far as this width allows, so it shrinks to
        // leave the transcript its minimum and grows back when there is room again. The saved
        // width is kept; only a drag of this divider changes it.
        let target = wantedWidth
        if !placed || abs(sidebarWidth - target) > 0.5 {
            placed = true
            place(target)
            // NSSplitView places its divider's layer in its own layout pass, which ran above at the
            // old position: lay out again, or a stale 1 pt line stays there, drawn through the
            // see-through chat (live-qa 2026-10-21: at 320 pt after a clamp to 164).
            super.layout()
        }
    }

    override public func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2, !list.isHidden, dividerRect.insetBy(dx: -Self.grab, dy: 0).contains(point) {
            resetWidth()
            return
        }
        super.mouseDown(with: event)
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// The list at `width` (clamped to this window), kept as the user's width (a divider drag's
    /// result without the drag: `debug.home.sidebar_fixture` width for screenshots).
    public func setWidth(_ width: CGFloat) {
        let width = clamp(width)
        widths.save(width, window: windowKey())
        place(width)
    }
    #endif

    /// Back to the standard width (the divider's double-click).
    public func resetWidth() {
        widths.reset(window: windowKey())
        place(clamp(standard))
    }

    private func updateChatCompose() {
        chatColumn.showsCompose = !composing
    }

    /// A narrow column squeezing a list of one conversation (only the Chief) to avatars would leave
    /// one avatar in an empty band beside the chat (visual QA 2026-10-21): it takes no column, and
    /// compose shows at the chat's top-left as for any avatar-only list. A list the person dragged
    /// to avatars keeps its column (and so the divider to drag it back); a wider column brings the
    /// list back at their width. Debug Settings can keep the column.
    var foldsLoneConversation: Bool {
        let own = widths.width(window: windowKey()) ?? standard
        // The list is the column less the panel's inset (`HomeSidebarView.panelInset`).
        let inset = HomeSidebarView.panelInset
        return list.holdsOneConversation && HomeSidebarHeaderLayout.isCompact(width: clamp(own) - inset)
            && !HomeSidebarHeaderLayout.isCompact(width: own - inset) && !HomeTunables.loneConversationRail.value(in: tunables)
    }

    /// Hides or shows the list for ``showsList`` and ``foldsLoneConversation``; true while it is folded.
    private func foldLoneConversation() -> Bool {
        // Another window may have shown or folded the list (one choice on this Mac): the button follows.
        if chatColumn.chats.isOn != widths.listShown { chatColumn.chats.isOn = widths.listShown }
        let fold = !widths.listShown || foldsLoneConversation
        if list.isHidden != fold {
            list.isHidden = fold
            // Shown again, the list goes back to its width below.
            placed = false
            adjustSubviews()
            // As after `place`: NSSplitView placed its divider's layer in the pass above, before
            // the fold, so lay out again or a stale line stays at the list's old edge (only
            // `layout()` calls this).
            super.layout()
            updateChatCompose()
        }
        return fold
    }

    private func followLoneConversationTunable() {
        withObservationTracking {
            _ = HomeTunables.loneConversationRail.value(in: tunables)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.needsLayout = true
                self?.followLoneConversationTunable()
            }
        }
    }

    private func place(_ width: CGFloat) {
        // A folded list has no divider to move: the next layout shows it if the width needs it.
        guard !list.isHidden else {
            needsLayout = true
            return
        }
        placing = true
        defer { placing = false }
        setPosition(width, ofDividerAt: 0)
    }

    // MARK: NSSplitViewDelegate

    public func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        minimum
    }

    public func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        clamp(.greatestFiniteMagnitude)
    }

    public func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }

    /// The folded list's divider takes no width either: the chat spans the split.
    public func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool { list.isHidden }

    public func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        // A window resize goes to the transcript; the sidebar keeps its width.
        view !== arrangedSubviews.first
    }

    public func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect,
                   ofDividerAt dividerIndex: Int) -> NSRect {
        drawnRect.insetBy(dx: -Self.grab, dy: 0)
    }

    override public func resizeSubviews(withOldSize oldSize: NSSize) {
        if slide != nil { return placeSlideFrame() }
        super.resizeSubviews(withOldSize: oldSize)
    }

    public func splitViewDidResizeSubviews(_ notification: Notification) {
        guard slide == nil else { return }
        // Every width change (a drag too, which runs no layout pass) moves compose to or from the chat.
        updateChatCompose()
        // Only the user's drag is kept (AppKit names the divider it moved).
        guard placed, !placing, notification.userInfo?["NSSplitViewDividerIndex"] != nil else { return }
        widths.save(sidebarWidth, window: windowKey())
    }
}
