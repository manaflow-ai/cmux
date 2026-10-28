public import AppKit
public import CmuxNextWakeups

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
///
/// The person switched to the incoming view and it has the keyboard, so the hold is short and
/// never outlives input (audit B1/B2, input-principles.md): it ends when the incoming view paints,
/// at ``limit`` (two 60 Hz frames), or when a key, click or scroll comes to its window, before that
/// event is delivered (``WindowPaintHolds/endAll()``), so no input goes to a view the person cannot
/// see. Content that has no frame by then shows its own first frame: an agent page its loading
/// state, a page tab its stand-in. Each hold's length and end is a row of ``VisibleHolds``
/// (`debug.input` `holds`).
@MainActor
public final class PanePaintHold {
    /// The longest the outgoing view stays: two 60 Hz frames. A page that has not reported its frame
    /// by then shows as it is (its loading state or stand-in). Under the precise-deadline bound
    /// (`DelayPolicy.maxPreciseDelay`), so the wake is not moved later.
    public static let limit: Duration = .milliseconds(33)
    /// What a hold waits for, as ``VisibleHolds`` names it.
    static let reason = "switched-to content not painted"

    private weak var outgoing: NSView?
    private weak var incoming: NSView?
    private var token: UInt64 = 0
    private var holding = false
    private var release: ((NSView) -> Void)?
    private var ended: (() -> Void)?
    /// The hold's limit: `visible`, since the person waits on the pane it keeps.
    private let deadline: MainDeadline
    private let owner: String
    private let holds: VisibleHolds
    /// When the hold on screen began (``VisibleHolds/now()``).
    private var began: UInt64 = 0
    /// The window's holds this hold is listed in while it holds.
    private weak var window: WindowPaintHolds?

    /// - Parameters:
    ///   - owner: The limit's owner on the board, and the hold's row in ``VisibleHolds``.
    ///   - deadlines: The app's one deadline placer (`AppServices.mainDeadlines`); its ``MainDeadlineScheduler/holds``
    ///     measures each hold.
    public init(owner: String, deadlines: MainDeadlineScheduler) {
        self.owner = owner
        holds = deadlines.holds
        deadline = MainDeadline(owner: owner, workClass: .visible, alignment: .precise, scheduler: deadlines)
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
        began = VisibleHolds.now()
        window = (host.window as? PaintHoldWindow)?.paintHolds
        window?.add(self)
        self.outgoing = outgoing
        self.incoming = incoming
        holding = true
        self.release = release
        self.ended = ended
        if incoming.superview === host {
            host.addSubview(incoming, positioned: .above, relativeTo: outgoing)
        }
        incoming.alphaValue = 0
        (incoming as? AgentPaneView)?.chatOpen?.mark(.holdBegin)
        #if DEBUG || CMUX_BENCH_HOOKS
        ChatOpenTrace.shared.mark(.holdBegin, view: incoming)
        #endif
        gated.whenFirstPainted { [weak self] in self?.finish(token, how: .shown) }
        // A later hold replaces this deadline; the token keeps it to its own hold.
        deadline.schedule(after: Self.limit) { [weak self] in
            self?.finish(token, how: .limit)
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
        unlist()
        holds.record(owner: owner, reason: Self.reason, limit: Self.limit, began: began, end: .replaced)
        release = nil
        ended = nil
        if let incoming {
            remove(incoming)
            // Page views are reused: one shown later must not stay invisible.
            incoming.alphaValue = 1
        }
        outgoing = nil
        incoming = nil
    }

    /// Ends the hold (only hold `token`, when given): the outgoing view goes
    /// and the incoming one shows, in one frame.
    public func end(_ token: UInt64? = nil) {
        finish(token, how: .replaced)
    }

    /// Ends the hold because the person's input in its window is about to be delivered.
    func endForInput() {
        finish(nil, how: .input)
    }

    private func unlist() {
        window?.remove(self)
        window = nil
    }

    private func finish(_ token: UInt64?, how: VisibleHolds.End) {
        guard holding, token == nil || self.token == token else { return }
        holding = false
        deadline.cancel()
        unlist()
        holds.record(owner: owner, reason: Self.reason, limit: Self.limit, began: began, end: how)
        let release = release
        let ended = ended
        self.release = nil
        self.ended = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let outgoing { release?(outgoing) }
        ended?()
        incoming?.alphaValue = 1
        CATransaction.commit()
        (incoming as? AgentPaneView)?.chatOpen?.mark(.holdEnd)
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
