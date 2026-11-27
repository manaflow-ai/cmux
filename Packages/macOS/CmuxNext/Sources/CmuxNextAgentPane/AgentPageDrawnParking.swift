public import AppKit
import CmuxNextDesignTokens
import CmuxNextPages
import CmuxNextWakeups

/// A chat in Chromium that a pane stops showing (a switch to another tab) waits drawn, off screen in its window,
/// instead of hidden in its pane, so the switch back shows its last laid-out frame at once.
///
/// Leo, 2026-11-15: "there is layout shift here... why..." Hidden in its pane, the chat's Chromium page was told
/// it is hidden: Chromium dropped its frame, and each switch back showed an empty pane for 0.5 to 1.25 s, then
/// the transcript drawing in as Chromium laid it out again (a long message's "Show more" row a frame late,
/// every row moving), then the composer's bottom bar. Parked here the page keeps drawing at the size it shows at
/// (in a ``PageOffscreenParking``: far outside the window content, which Chromium does not count as hidden), and
/// the pane takes it back in place at that size (``AgentPaneView/placeMovedChromiumPage(requiringFrame:moved:)``),
/// so it shows in that layout's frame with nothing left to lay out. To the document and its owner it is hidden
/// all the same (``PageWebView/setDrawnAway(_:)``): unread turns, animations, question keys.
///
/// One per window, a subview of its content view made at the first park, so its state lives and goes with the
/// window. Bounded, a constant cost whatever the tab count: at most ``limit`` chats draw here, each for
/// ``keepFor`` (the hidden-tab freeze's default wait, `browser.freezeHiddenTabs`); none in Low Power Mode. A chat
/// past either goes hidden where it waits, as a hidden pane's chat does (hibernation's freeze and idle release
/// take it from there), after its last frame is pictured: the switch back shows that picture under the page until
/// the page drew again (``Return/hidden(cover:)``). At most ``coverLimit`` pictures are kept.
@MainActor
public final class AgentPageDrawnParking: NSView {
    /// Chats kept drawn per window.
    public static let limit = 2
    /// Pictures of chats gone hidden kept per window.
    public static let coverLimit = 4
    /// How long one stays drawn after its pane stopped showing it.
    public static let keepFor: Duration = .seconds(30)
    /// How long the picture of a chat going hidden may take; past it, it goes hidden with none.
    static let pictureDeadline: Duration = .seconds(2)

    /// How a chat comes back.
    public enum Return {
        /// It did not wait here.
        case none
        /// Drawn: it shows at once, as it last drew.
        case drawn
        /// Hidden (past its time or the window's limit): its last frame, when one was pictured, stands in until it draws.
        case hidden(cover: NSImage?)
    }

    private final class Entry {
        weak var view: AgentPaneView?
        let timer = DemandTimer(owner: "AgentPageDrawnParking.keep")
        var hidden = false
        var cover: NSImage?
        init(_ view: AgentPaneView) { self.view = view }
    }

    /// Where the chats wait, far outside the window content.
    private let parking = PageOffscreenParking()
    /// Oldest first.
    private var entries: [Entry] = []
    /// Tests drive the picture without a page engine.
    var snapshotOverride: (@MainActor (AgentPaneView) async -> NSImage?)?

    private init() {
        super.init(frame: .zero)
        autoresizingMask = []
        setAccessibilityElement(false)
        setAccessibilityHidden(true)
        parking.autoresizingMask = []
        addSubview(parking)
    }

    public required init?(coder: NSCoder) { nil }

    override public func hitTest(_ point: NSPoint) -> NSView? { nil }
    override public var acceptsFirstResponder: Bool { false }
    override public func accessibilityChildren() -> [Any]? { [] }

    /// `window`'s keeper; nil before its first park.
    public static func of(_ window: NSWindow?) -> AgentPageDrawnParking? {
        window?.contentView?.subviews.lazy.compactMap { $0 as? AgentPageDrawnParking }.first
    }

    /// The keeper `view` waits in, drawn or gone hidden there.
    static func holding(_ view: NSView) -> AgentPageDrawnParking? {
        view.superview?.superview as? AgentPageDrawnParking
    }

    /// The chats drawn here now (tests, debug).
    public var drawnCount: Int { entries.filter { !$0.hidden }.count }

    /// Whether `view` is one to keep drawn: a chat (no New Tab page) in Chromium that drew, shown in a window, with
    /// no crash notice and no dictation running.
    static func keeps(_ view: AgentPaneView) -> Bool {
        view.pageDrawsOverCovers && view.page?.showsChromium == true && view.model.hasPainted && view.model.newTab == nil
            && view.window?.contentView != nil && !view.isHiddenOrHasHiddenAncestor && !view.showsCrashNotice
            && view.dictation.phase.isStartable && !LowPowerMode.system.isEnabled
    }

    /// Parks `view` (its pane stops showing it) drawn, at its size, in its window's keeper; false when it is not one
    /// to keep (``keeps(_:)``), and the pane hides it as before.
    public static func park(_ view: AgentPaneView) -> Bool {
        guard keeps(view), let content = view.window?.contentView else { return false }
        let keeper = of(view.window) ?? {
            let made = AgentPageDrawnParking()
            content.addSubview(made, positioned: .below, relativeTo: nil)
            return made
        }()
        keeper.park(view, in: content)
        return true
    }

    private func park(_ view: AgentPaneView, in content: NSView) {
        prune()
        let size = view.frame.size
        // Far outside the content, in this keeper's coordinates (it sits at the content's origin).
        let away = PageOffscreenParking.frame(in: content.bounds, size: CGSize(width: max(parking.frame.width, size.width),
                                                                               height: max(parking.frame.height, size.height)))
        parking.frame = convert(away, from: content)
        view.autoresizingMask = []
        // One reparent inside the window: the page keeps its window and its frame.
        parking.addSubview(view)
        view.frame = CGRect(origin: .zero, size: size)
        view.wentAwayDrawn()
        let entry = Entry(view)
        entries.append(entry)
        entry.timer.schedule(after: Self.keepFor) { @MainActor [weak self, weak entry] in
            guard let self, let entry else { return }
            goHidden(entry)
        }
        let drawn = entries.filter { !$0.hidden }
        if drawn.count > Self.limit, let oldest = drawn.first { goHidden(oldest) }
    }

    /// A pane shows `view` again: it leaves its keeper, and the pane moves it in. Its page follows it into the pane at
    /// the next layout, at the size it waited at.
    public static func takeBack(_ view: AgentPaneView) -> Return {
        guard let keeper = holding(view) else { return .none }
        return keeper.takeBack(view)
    }

    private func takeBack(_ view: AgentPaneView) -> Return {
        let entry = entries.firstIndex { $0.view === view }.map { entries.remove(at: $0) }
        entry?.timer.cancel()
        view.cameBackDrawn()
        view.placeMovedChromiumPage()
        guard entry?.hidden ?? view.isHidden else { return .drawn }
        return .hidden(cover: entry?.cover)
    }

    /// ``takeBack(_:)`` into `host` (a pane's content area, `cover` the pane that draws covers) at `frame`, the frame it
    /// shows at (the size it waited at): drawn, it shows in this layout's frame with nothing to lay out again; gone
    /// hidden, its last frame stands under it until it drew again. False when it did not wait here.
    public static func install(_ view: AgentPaneView, in host: NSView, at frame: NSRect, fills: Bool, cover: any AgentPaneMoveCoverHost) -> Bool {
        let back = takeBack(view)
        if case .none = back { return false }
        host.addSubview(view)
        view.autoresizingMask = fills ? [.width, .height] : []
        if view.frame != frame { view.frame = frame }
        if case .hidden(let picture?) = back {
            cover.showLaunchImage(picture, limit: .seconds(3))
            view.standOverPicture()
            cover.onLaunchImageCleared = { [weak view] in view?.pictureBelowWent() }
            view.redraw.afterNextFrame { [weak cover] in
                guard let cover, let image = cover.launchImageView else { return }
                cover.clearLaunchImage(ifShowing: image)
            }
        }
        view.isHidden = false
        return true
    }

    /// Past its time or the window's limit: its last frame is pictured, then it goes hidden where it waits (its
    /// engine stops drawing it).
    private func goHidden(_ entry: Entry) {
        entry.timer.cancel()
        guard !entry.hidden, let view = entry.view, view.superview === parking else { return prune() }
        entry.hidden = true
        let covered = entries.filter { $0.hidden && $0.cover != nil }
        if covered.count >= Self.coverLimit, let oldest = covered.first { oldest.cover = nil }
        let snapshot = snapshotOverride
        // Bounded: a picture that never comes (a hung renderer) must not keep the chat drawn, and off the limit,
        // forever. Past the deadline it goes hidden with no picture; a later picture is dropped.
        entry.timer.schedule(after: Self.pictureDeadline) { @MainActor [weak self, weak entry, weak view] in
            guard let self, let entry, let view, entry.hidden, entry.view === view, view.superview === parking else { return }
            view.isHidden = true
        }
        // task-owner: one picture of a chat leaving the drawn keep; it hides when the picture is in
        Task { @MainActor [weak self, weak entry, weak view] in
            guard let view else { return }
            // The saved-frame picture (#43281): a Chromium page's clear areas over the color under the page; nil when
            // no picture can stand in for it.
            let image: NSImage? = if let snapshot { await snapshot(view) } else { await view.pageImage() }
            guard let self, let entry, entry.hidden, entry.view === view, view.superview === parking, !view.isHidden else { return }
            entry.timer.cancel()
            entry.cover = image
            // Still away to the document: hidden now, it reads as hidden until a pane takes it back.
            view.isHidden = true
        }
    }

    /// Drops the books of chats that left (taken into a pane, closed, released).
    private func prune() {
        entries.removeAll { entry in
            guard let view = entry.view, view.superview === parking else {
                entry.timer.cancel()
                return true
            }
            return false
        }
    }
}

extension AgentPaneView {
    /// In a window, not hidden, and not waiting drawn off screen (``AgentPageDrawnParking``): what a person can see.
    public var isShownToPerson: Bool { window != nil && !isHiddenOrHasHiddenAncestor && page?.isDrawnAway != true }

    /// Its pane stopped showing it and it waits drawn (``AgentPageDrawnParking``): what hiding it ends, ends.
    func wentAwayDrawn() {
        dictation.handle(.stop)
        popupHostStorage?.dismiss()
        page?.setDrawnAway(true)
        transportPacer?.visibilityChanged()
        toastAvoidanceMoved()
        if let page { PageWebView.syncChromiumVisibility(in: page) }
        // A Chromium page's window follows its view only when told.
        page?.chromiumWindowMoved()
    }

    /// Shown again: the page is no longer drawn away.
    func cameBackDrawn() {
        page?.setDrawnAway(false)
        transportPacer?.visibilityChanged()
        toastAvoidanceMoved()
    }
}
