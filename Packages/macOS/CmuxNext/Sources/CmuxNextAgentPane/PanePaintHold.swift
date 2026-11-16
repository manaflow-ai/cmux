public import AppKit
import CmuxNextPages
import CmuxNextWakeups

/// Content that draws nothing until its document paints (an agent page is
/// transparent until then). A pane switching to it keeps what it showed
/// until it paints, instead of showing an empty pane in between.
@MainActor
public protocol PaneFirstPaintGated: AnyObject {
    var awaitsFirstPaint: Bool { get }
    /// Runs `body` once the content has painted (now if it has).
    func whenFirstPainted(_ body: @escaping () -> Void)
}

/// The outgoing view a container (a pane, or the window's content area
/// under a top page) keeps on screen while the incoming one, above it and
/// invisible, has not painted.
@MainActor
public final class PanePaintHold {
    /// The longest the outgoing view stays: a page that never reports its
    /// first frame shows as it is after this.
    public static let limit: Duration = .milliseconds(500)

    private weak var outgoing: NSView?
    private weak var incoming: NSView?
    private var token: UInt64 = 0
    private var holding = false
    private var release: ((NSView) -> Void)?
    private var ended: (() -> Void)?
    private let deadline: DemandTimer
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

    public init(owner: String) {
        deadline = DemandTimer(owner: owner)
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
        // A later hold replaces this deadline; the token keeps it to its own hold.
        deadline.schedule(after: Self.limit) { @MainActor [weak self] in
            self?.end(token)
        }
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
