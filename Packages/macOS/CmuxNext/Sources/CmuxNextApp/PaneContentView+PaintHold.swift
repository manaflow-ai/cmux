import AppKit
import CmuxNextAgentPane
import CmuxNextDesign
import CmuxNextPages
import CmuxNextWakeups

/// Content that draws nothing until its document paints (an agent page is
/// transparent until then). A pane switching to it keeps what it showed
/// until it paints, instead of showing an empty pane in between.
@MainActor
protocol PaneFirstPaintGated: AnyObject {
    var awaitsFirstPaint: Bool { get }
    /// Runs `body` once the content has painted (now if it has).
    func whenFirstPainted(_ body: @escaping () -> Void)
}

extension AgentPaneView: PaneFirstPaintGated {
    var awaitsFirstPaint: Bool { !model.hasPainted }

    func whenFirstPainted(_ body: @escaping () -> Void) {
        model.whenPainted(body)
    }
}

/// A page tab: transparent until its document paints, like an agent page
/// (no-flicker audit). Content that is not a page has nothing to wait for.
extension InternalPageView: PaneFirstPaintGated {
    var awaitsFirstPaint: Bool { (content as? PageWebView).map { !$0.hasPainted } ?? false }

    func whenFirstPainted(_ body: @escaping () -> Void) {
        guard let page = content as? PageWebView else { return body() }
        page.whenPainted(body)
    }
}

/// The outgoing view a container (a pane, or the window's content area
/// under a top page) keeps on screen while the incoming one, above it and
/// invisible, has not painted.
@MainActor
final class PanePaintHold {
    /// The longest the outgoing view stays: a page that never reports its
    /// first frame shows as it is after this.
    static let limit: Duration = .milliseconds(500)

    private weak var outgoing: NSView?
    private weak var incoming: NSView?
    private var token: UInt64 = 0
    private var holding = false
    private var release: ((NSView) -> Void)?
    private let deadline: DemandTimer

    init(owner: String) {
        deadline = DemandTimer(owner: owner)
    }

    /// Whether `view` replacing `hosted` waits for its first frame. Content
    /// that hid itself when withdrawn (an internal page) has nothing to keep.
    static func holds(_ view: NSView?, replacing hosted: NSView?) -> Bool {
        guard let hosted, let view, hosted !== view, !hosted.isHidden else { return false }
        return (view as? PaneFirstPaintGated)?.awaitsFirstPaint == true
    }

    /// `incoming` (moved above `outgoing` in `host`) stays invisible until it
    /// paints or ``limit`` passes; `outgoing` stays shown until then.
    /// `release` takes `outgoing` away when the hold ends.
    func begin(outgoing: NSView, incoming: NSView, in host: NSView, release: @escaping (NSView) -> Void) {
        guard let gated = incoming as? PaneFirstPaintGated else { return }
        token &+= 1
        let token = token
        self.outgoing = outgoing
        self.incoming = incoming
        holding = true
        self.release = release
        if incoming.superview === host {
            host.addSubview(incoming, positioned: .above, relativeTo: outgoing)
        }
        incoming.alphaValue = 0
        gated.whenFirstPainted { [weak self] in self?.end(token) }
        // A later hold replaces this deadline; the token keeps it to its own hold.
        deadline.schedule(after: Self.limit) { @MainActor [weak self] in
            self?.end(token)
        }
    }

    /// Ends the hold (only hold `token`, when given): the outgoing view goes
    /// and the incoming one shows, in one frame.
    func end(_ token: UInt64? = nil) {
        guard holding, token == nil || self.token == token else { return }
        holding = false
        deadline.cancel()
        let release = release
        self.release = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let outgoing { release?(outgoing) }
        incoming?.alphaValue = 1
        CATransaction.commit()
        outgoing = nil
        incoming = nil
    }
}

extension PaneContentView {
    /// Whether `view` replacing `hosted` waits for its first frame.
    func holdsForFirstPaint(_ view: NSView?, replacing hosted: NSView?) -> Bool {
        PanePaintHold.holds(view, replacing: hosted)
    }

    /// `incoming` stays invisible until it paints; `outgoing` stays shown until then.
    func beginPaintHold(outgoing: NSView, incoming: NSView) {
        paintHold.begin(outgoing: outgoing, incoming: incoming, in: contentHost) { [weak self] outgoing in
            guard let self, outgoing.superview === contentHost, outgoing !== content else { return }
            outgoing.removeFromSuperview()
            (outgoing as? PaneContentChrome)?.onPaneHeaderHeightChange = nil
        }
    }

    /// Ends the hold: the outgoing view goes and the incoming one shows, in one frame.
    func endPaintHold() {
        paintHold.end()
    }
}
