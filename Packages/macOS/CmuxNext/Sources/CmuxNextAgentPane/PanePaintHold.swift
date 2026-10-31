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
    public func begin(outgoing: NSView, incoming: NSView, in host: NSView, release: @escaping (NSView) -> Void,
               ended: (() -> Void)? = nil) {
        guard let gated = incoming as? PaneFirstPaintGated else { return }
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
        if let outgoing { release?(outgoing) }
        incoming?.alphaValue = 1
        if let incoming { PageWebView.syncChromiumVisibility(in: incoming) }
        if let outgoing { PageWebView.syncChromiumVisibility(in: outgoing) }
        ended?()
        CATransaction.commit()
        #if DEBUG || CMUX_BENCH_HOOKS
        if let incoming { ChatOpenTrace.shared.mark(.holdEnd, view: incoming) }
        #endif
        outgoing = nil
        incoming = nil
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
