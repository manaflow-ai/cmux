public import AppKit
import CmuxNextPages
import CmuxNextWakeups

/// Content that draws nothing until its document paints (an agent page is
/// transparent until then). A pane switching to it keeps what it showed
/// until it paints, instead of showing an empty pane in between.
@MainActor
public protocol PaneFirstPaintGated: AnyObject {
    var awaitsFirstPaint: Bool { get }
    /// It has drawn no frame at all yet (not one that only waits to draw again at a new size).
    var neverPainted: Bool { get }
    /// Runs `body` once the content has painted (now if it has).
    func whenFirstPainted(_ body: @escaping () -> Void)
    /// A hold gave up on it before it painted (its limit passed) and shows it now: it shows the picture it keeps of
    /// itself (a chat's or New Tab page's last frame) until it paints, never a clear or empty frame. One with no
    /// picture (a brand-new chat) shows as it is.
    func standInUntilPainted()
}

extension PaneFirstPaintGated {
    public var neverPainted: Bool { awaitsFirstPaint }
    public func standInUntilPainted() {}
}

/// The outgoing view a container (a pane, or the window's content area
/// under a top page) keeps on screen while the incoming one, above it and
/// invisible, has not painted.
@MainActor
public final class PanePaintHold {
    /// The longest a pane's outgoing tab stays: a page that never reports its
    /// first frame shows as it is after this.
    public static let limit: Duration = .milliseconds(500)

    /// `count` frames of a display that draws `framesPerSecond` (33 ms for two at 60 Hz, 17 ms at 120 Hz).
    public static func frames(_ count: Int, at framesPerSecond: Int) -> Duration {
        .nanoseconds(Int64(count) * 1_000_000_000 / Int64(max(1, framesPerSecond)))
    }

    /// How often `view`'s screen draws: its window's screen, else the main one, else 60 Hz.
    public static func framesPerSecond(of view: NSView) -> Int {
        let rate = view.window?.screen?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? 60
        return rate > 0 ? rate : 60
    }

    private let owner: String
    /// How many frames of the host's screen a hold lasts at most; nil: ``limit``.
    private let frames: Int?
    /// Times the limit; a test sets its own before the first hold.
    public var clock: any Clock<Duration> = ContinuousClock() {
        didSet { deadline = DemandTimer(owner: owner, clock: clock) }
    }
    /// How often the screen showing a host draws; a test sets its own.
    public var displayFramesPerSecond: @MainActor (NSView) -> Int = { PanePaintHold.framesPerSecond(of: $0) }

    private weak var outgoing: NSView?
    private weak var incoming: NSView?
    private var token: UInt64 = 0
    private var holding = false
    private var release: ((NSView) -> Void)?
    private var ended: (() -> Void)?
    private var deadline: DemandTimer
    /// Where the outgoing view shows in the container (``begin(outgoing:incoming:in:keepingPlaceIn:release:ended:)``).
    private var place: KeptPlace?
    /// Work that waits for the kept view to stop showing (``afterHold(of:_:)``); it outlives a hand-off to the next hold.
    private var afterEnd: [() -> Void] = []

    private struct KeptPlace {
        weak var view: NSView?
        weak var host: NSView?
        weak var container: NSView?
        /// The view's frame in the container's coordinates, and the container's size then.
        let frame: NSRect
        let containerSize: NSSize
        let autoresizingMask: NSView.AutoresizingMask
    }

    /// `frames`: a hold lasts that many frames of its host's screen at most (two for the window's workspace swap: 33 ms at
    /// 60 Hz, 17 ms at 120 Hz); nil keeps ``limit``. Past it the incoming view shows, and a page in it that has not
    /// painted stands in with its picture (``PaneFirstPaintGated/standInUntilPainted()``).
    public init(owner: String, frames: Int? = nil) {
        self.owner = owner
        self.frames = frames
        deadline = DemandTimer(owner: owner)
    }

    /// The longest a hold in `host` keeps the outgoing view.
    private func limit(in host: NSView) -> Duration {
        frames.map { Self.frames($0, at: displayFramesPerSecond(host)) } ?? Self.limit
    }

    /// Whether `view` replacing `hosted` waits for its first frame. Content
    /// that hid itself when withdrawn (an internal page) has nothing to keep.
    public static func holds(_ view: NSView?, replacing hosted: NSView?) -> Bool {
        guard let hosted, let view, hosted !== view, !hosted.isHidden else { return false }
        return (view as? PaneFirstPaintGated)?.awaitsFirstPaint == true
    }

    /// `incoming` (moved above `outgoing` in `host`) stays invisible until it
    /// paints or ``limit`` passes; `outgoing` stays shown until then.
    /// `release` takes `outgoing` away when the hold ends.
    /// `ended` runs when it ends, with or without an outgoing view left to release.
    /// `container`: `outgoing` keeps its place in it until the swap (``placeKept()``), whatever frame `host` takes.
    public func begin(outgoing: NSView, incoming: NSView, in host: NSView, keepingPlaceIn container: NSView? = nil,
                      release: @escaping (NSView) -> Void, ended: (() -> Void)? = nil) {
        guard let gated = incoming as? PaneFirstPaintGated else { return }
        keepPlace(of: outgoing, in: host, container: container)
        token &+= 1
        let token = token
        self.outgoing = outgoing
        self.incoming = incoming
        holding = true
        self.release = release
        self.ended = ended
        if incoming.superview === host {
            host.addSubview(incoming, positioned: .above, relativeTo: outgoing)
        }
        incoming.alphaValue = 0
        PageWebView.syncChromiumVisibility(in: incoming)
        #if DEBUG || CMUX_BENCH_HOOKS
        ChatOpenTrace.shared.mark(.holdBegin, view: incoming)
        #endif
        gated.whenFirstPainted { [weak self] in self?.end(token) }
        // A later hold replaces this deadline; the token keeps it to its own hold. A hand-off to the next swap starts the
        // next one's own limit: a run of swaps faster than the limit keeps one view on screen and never shows the views it
        // passes over (ending holds mid-burst showed each one and started a new hold on it, cmux#44329).
        deadline.schedule(after: limit(in: host)) { @MainActor [weak self] in
            self?.endAtLimit(token)
        }
    }

    /// The limit passed before `incoming` painted: it, or each shown page in it that has not painted (a workspace's chats
    /// and New Tab pages, ``UnpaintedPages``), stands in with its picture, in the frame the hold ends.
    private func endAtLimit(_ token: UInt64) {
        guard holding, self.token == token, let incoming else { return end(token) }
        (incoming as? PaneFirstPaintGated)?.standInUntilPainted()
        for page in UnpaintedPages(in: incoming).pages { page.standInUntilPainted() }
        end(token)
    }

    /// The view this hold keeps on screen, while it holds.
    public var kept: NSView? { holding ? outgoing : nil }

    /// Runs `body` when `view`, which this hold keeps on screen, stops showing (the incoming view showed); false when
    /// this hold keeps no such view and the caller goes on now. A kept workspace closed meanwhile is torn down then,
    /// not under the incoming one that has not painted (an empty frame until it did).
    public func afterHold(of view: NSView, _ body: @escaping () -> Void) -> Bool {
        guard kept === view else { return false }
        afterEnd.append(body)
        return true
    }

    /// A newer swap that waits too takes over: the incoming view, which never
    /// showed, leaves through `remove`, and ``kept`` stays on screen for the
    /// next hold (no empty frame between two pages that have not painted).
    public func handOff(remove: (NSView) -> Void) {
        guard holding else { return }
        holding = false
        deadline.cancel()
        release = nil
        ended = nil
        if let incoming {
            remove(incoming)
            // Page views are reused: one shown later must not stay invisible.
            incoming.alphaValue = 1
            PageWebView.syncChromiumVisibility(in: incoming)
        }
        outgoing = nil
        incoming = nil
    }

    /// Ends the hold (only hold `token`, when given): the outgoing view goes
    /// and the incoming one shows, in one frame.
    public func end(_ token: UInt64? = nil) {
        guard holding, token == nil || self.token == token else { return }
        holding = false
        deadline.cancel()
        let release = release
        let ended = ended
        self.release = nil
        self.ended = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        releasePlace()
        if let outgoing { release?(outgoing) }
        incoming?.alphaValue = 1
        if let incoming { PageWebView.syncChromiumVisibility(in: incoming) }
        if let outgoing { PageWebView.syncChromiumVisibility(in: outgoing) }
        ended?()
        // The kept view stopped showing in this transaction: what waited for that (a teardown) goes in it too.
        let after = afterEnd
        afterEnd = []
        after.forEach { $0() }
        CATransaction.commit()
        #if DEBUG || CMUX_BENCH_HOOKS
        if let incoming { ChatOpenTrace.shared.mark(.holdEnd, view: incoming) }
        #endif
        outgoing = nil
        incoming = nil
    }

    /// The host takes the incoming view's frame at once: the whole pane for a chat whose tools share the tab row, the
    /// area under the strip for a New Tab page, a terminal or a browser. An outgoing view sized with it moved by the
    /// strip's height while it stayed shown: its page, laid out for its old frame, showed shifted with its composer cut
    /// off, and a chat shown again drew a frame laid out at the other height before it snapped back (Leo 2026-11-15:
    /// "there is layout shift here... why..."). It keeps its frame in `container` instead. A hold handed to the next
    /// swap (``handOff(remove:)``) keeps the place its view took first.
    private func keepPlace(of view: NSView, in host: NSView, container: NSView?) {
        if place?.view === view, container != nil, view.autoresizingMask.isEmpty { return }
        releasePlace()
        guard let container, view.superview === host else { return }
        place = KeptPlace(view: view, host: host, container: container, frame: container.convert(view.frame, from: host),
                          containerSize: container.bounds.size, autoresizingMask: view.autoresizingMask)
        view.autoresizingMask = []
    }

    /// Puts the kept view back at its place in the container after the host's frame changed; a container resized during
    /// the hold grows or shrinks it by as much, as autoresizing did.
    public func placeKept() {
        guard let place, let view = place.view, let host = place.host, let container = place.container,
              holding, view === outgoing, view.superview === host else { return }
        var frame = place.frame
        frame.size.width = max(0, frame.width + container.bounds.width - place.containerSize.width)
        frame.size.height = max(0, frame.height + container.bounds.height - place.containerSize.height)
        let target = host.convert(frame, from: container)
        if view.frame != target { view.frame = target }
    }

    /// The kept view resizes with its host again.
    private func releasePlace() {
        guard let kept = place else { return }
        place = nil
        kept.view?.autoresizingMask = kept.autoresizingMask
    }
}

/// A page in a workspace that draws its own frames (a chat's web page). Parked with its workspace,
/// it draws nothing, and shown again it shows the last frame it drew, at the size it drew it, until
/// it lays out again.
@MainActor
public protocol WorkspacePageRedrawing: AnyObject {
    /// It drew before. One that has not covers itself with its own loading state.
    var hasDrawnFrame: Bool { get }
    /// Runs `body` once it drew at the size it shows at after the next layout.
    func whenRedrawn(_ body: @escaping () -> Void)
}

extension AgentPaneView: WorkspacePageRedrawing {
    public var hasDrawnFrame: Bool { model.hasPainted }
    public func whenRedrawn(_ body: @escaping () -> Void) { redraw.when(self, body) }
}

/// The pages that drew before in `root`'s shown part: not in a hidden tab or pane, not in a column
/// scrolled out of the viewport.
@MainActor
public struct DrawnPages {
    public let pages: [any WorkspacePageRedrawing]

    public init(in root: NSView) {
        var found: [any WorkspacePageRedrawing] = []
        func visit(_ view: NSView) {
            for child in view.subviews where !child.isHidden {
                guard let page = child as? any WorkspacePageRedrawing else {
                    visit(child)
                    continue
                }
                if page.hasDrawnFrame, child.convert(child.bounds, to: root).intersects(root.bounds) { found.append(page) }
            }
        }
        visit(root)
        pages = found
    }

    /// Runs `body` once every page drew at the size it shows at after the next layout (now with none).
    /// Ask before the layout that resizes them: a page notes its new size as it lays out.
    public func whenRedrawn(_ body: @escaping () -> Void) {
        var left = pages.count
        guard left > 0 else { return body() }
        for page in pages {
            page.whenRedrawn {
                left -= 1
                if left == 0 { body() }
            }
        }
    }
}

/// The pages in `root`'s shown part that have drawn no frame yet: a new or cold workspace's New Tab page or chat.
/// Shown as they are, they are clear (a New Tab page hides its cover) or their loading cover, not the workspace's
/// content. A page its pane already keeps unseen (its own hold, alpha 0) is not counted: the pane shows what it kept.
@MainActor
public struct UnpaintedPages {
    public let pages: [any PaneFirstPaintGated]

    public init(in root: NSView) {
        var found: [any PaneFirstPaintGated] = []
        // A view not laid out yet (a workspace built in this turn) has no viewport to clip by.
        let clips = !root.bounds.isEmpty
        func visit(_ view: NSView) {
            for child in view.subviews where !child.isHidden && child.alphaValue > 0 {
                guard let page = child as? any PaneFirstPaintGated else {
                    visit(child)
                    continue
                }
                if page.neverPainted, !clips || child.convert(child.bounds, to: root).intersects(root.bounds) { found.append(page) }
            }
        }
        visit(root)
        pages = found
    }

    /// Runs `body` once every page painted its first frame (now with none).
    public func whenPainted(_ body: @escaping () -> Void) {
        var left = pages.count
        guard left > 0 else { return body() }
        for page in pages {
            page.whenFirstPainted {
                left -= 1
                if left == 0 { body() }
            }
        }
    }
}

extension NSView {
    /// Neither it nor an ancestor is fully transparent. A view a hold keeps unseen (``PanePaintHold``, on it or on
    /// its whole workspace) shows in one frame when the hold ends, so nothing it starts then is seen half done.
    public var isOpaqueUpToItsWindow: Bool {
        sequence(first: self, next: \.superview).allSatisfy { $0.alphaValue > 0 }
    }
}

extension AgentPaneView {
    /// Its page drew no frame yet (``PaneFirstPaintGated/neverPainted``); a redraw at a new size is not this.
    public var neverPainted: Bool { !model.hasPainted }
    /// A hold gave up on it before it painted: its pane draws its picture under it (``drawsLastPage``). A chat with none
    /// (a brand-new one) shows its loading state, as before.
    public func standInUntilPainted() {
        if !model.hasPainted { drawsLastPage?() }
    }
}

/// What a workspace's first frame waits for when the window shows it in place of another: its shown pages that never
/// painted (``UnpaintedPages``), and, `resized` (shown again at another size than it was parked at), its chats drawn at
/// the new size (``DrawnPages``). A tab switch in a pane waits for the same pages (``PanePaintHold``).
@MainActor
public struct WorkspaceFirstFrame {
    private let root: NSView

    public init(of root: NSView) {
        self.root = root
    }

    /// Whether the window keeps the outgoing workspace until ``whenReady(_:)`` answers. `prerendered`: the view was laid
    /// out and drawn off screen in the window before it was asked for (Cmd-N's reserved view, its settled design); it
    /// shows at once, in the key's frame.
    public func awaits(resized: Bool, prerendered: Bool = false) -> Bool {
        guard !prerendered else { return false }
        return !UnpaintedPages(in: root).pages.isEmpty || resized && !DrawnPages(in: root).pages.isEmpty
    }

    /// Runs `body` once every unpainted page painted and every drawn one drew at the size it shows at.
    ///
    /// Lays `root` out now only for chats that drew before: they note their new size as they lay out. Pages that never
    /// painted paint after the window's own layout pass (`WindowRootView.show` sized the workspace, which marks it), so
    /// a workspace replaced before that pass (the next of fifty quick Cmd-Ns hands its hold off) is never laid out, and
    /// a burst of presses costs what one does (cmux#44329). It is not marked again here: a hidden view keeps the mark,
    /// and every later pass of the window walked each hidden workspace so marked.
    public func whenReady(_ body: @escaping () -> Void) {
        var left = 2
        let one = {
            left -= 1
            if left == 0 { body() }
        }
        let drawn = DrawnPages(in: root)
        UnpaintedPages(in: root).whenPainted(one)
        drawn.whenRedrawn(one)
        if !drawn.pages.isEmpty { root.layoutSubtreeIfNeeded() }
    }
}

/// A container whose ``PanePaintHold`` may keep a view it swapped out on screen until the incoming view paints (the
/// window's content area).
@MainActor
public protocol PaintHoldHosting: AnyObject {
    var paintHold: PanePaintHold { get }
}

extension NSView {
    /// Defers `body` while a container's hold keeps this view on screen: it runs when the hold ends, in that frame.
    /// False when no hold keeps it (run it now).
    public func deferredPastPaintHold(_ body: @escaping () -> Void) -> Bool {
        let holds = sequence(first: self, next: { $0.superview }).dropFirst().lazy.compactMap { ($0 as? PaintHoldHosting)?.paintHold }
        return holds.contains { $0.afterHold(of: self, body) }
    }
}
