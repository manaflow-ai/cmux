import AppKit
import CmuxNextAgentPane
import CmuxNextBrowser
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
    /// The longest the outgoing view stays for it.
    var paintHoldLimit: Duration { get }
}

extension PaneFirstPaintGated {
    var paintHoldLimit: Duration { PanePaintHold.limit }
}

/// One that painted and is shown again waits for its frame at the size it
/// shows at (`AgentPageRedraw`).
extension AgentPaneView: PaneFirstPaintGated {
    var awaitsFirstPaint: Bool { !model.hasPainted || redraw.awaits(self) }

    func whenFirstPainted(_ body: @escaping () -> Void) {
        guard model.hasPainted else { return model.whenPainted(body) }
        // It may answer from this view's own layout(): the hold ends once the window's pass is done.
        redraw.when(self) { [weak self] in
            if let window = self?.window as? ShellWindow { window.afterLayoutPass(body) } else { body() }
        }
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

/// A WebKit page parked hidden in the pane (`PaneContentView+Parking`):
/// WebKit stopped rendering it, and shown again it draws its toolbar over an
/// empty page for a frame or two. The pane keeps the outgoing tab until it
/// renders, briefly: a busy page shows as it is sooner than an agent page.
extension BrowserChromeView: PaneFirstPaintGated {
    var awaitsFirstPaint: Bool { isHidden && tab is WebKitTab }
    var paintHoldLimit: Duration { .milliseconds(150) }

    func whenFirstPainted(_ body: @escaping () -> Void) {
        guard let page = tab as? WebKitTab else { return body() }
        WebKitRenderProbe.afterNextRender(page.webView, body)
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
    private var ended: (() -> Void)?
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
    /// `ended` runs when it ends, with or without an outgoing view left to release.
    func begin(outgoing: NSView, incoming: NSView, in host: NSView, release: @escaping (NSView) -> Void,
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
        gated.whenFirstPainted { [weak self] in self?.end(token) }
        // A later hold replaces this deadline; the token keeps it to its own hold.
        deadline.schedule(after: gated.paintHoldLimit) { @MainActor [weak self] in
            self?.end(token)
        }
    }

    /// The view this hold keeps on screen, while it holds.
    var kept: NSView? { holding ? outgoing : nil }

    /// A newer swap that waits too takes over: the incoming view, which never
    /// showed, leaves through `remove`, and ``kept`` stays on screen for the
    /// next hold (no empty frame between two pages that have not painted).
    func handOff(remove: (NSView) -> Void) {
        guard holding else { return }
        holding = false
        deadline.cancel()
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
    func end(_ token: UInt64? = nil) {
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
        ended?()
        incoming?.alphaValue = 1
        CATransaction.commit()
        outgoing = nil
        incoming = nil
    }
}

extension PaneContentView {
    /// Whether `view` replacing `hosted` waits for its first frame.
    func holdsForFirstPaint(_ view: NSView?, replacing hosted: NSView?) -> Bool {
        // A browser whose header band the strip joins shows at once: the strip moves with it.
        if view is any PaneHeaderBandHosting, barOrder == .belowToolbar, barPosition == .top { return false }
        return PanePaintHold.holds(view, replacing: hosted)
    }

    /// `incoming` stays invisible until it paints; `outgoing` stays shown until then.
    /// A strip that hides with this swap (the tab over a lone chat closed)
    /// stays, and `outgoing` keeps its place under it: the pane changes in
    /// one frame, when the swap shows (cx-f6i7).
    func beginPaintHold(outgoing: NSView, incoming: NSView) {
        if hidesStrip, !stripView.isHidden, !isBandActive, outgoing.frame.height > 0 {
            holdKeepsStrip = true
            // The host is not flipped: a fixed height on the strip's far side.
            outgoing.autoresizingMask = barPosition == .top ? [.width, .maxYMargin] : [.width, .minYMargin]
        }
        paintHold.begin(outgoing: outgoing, incoming: incoming, in: contentHost, release: { [weak self] outgoing in
            guard let self, outgoing.superview === contentHost, outgoing !== content else { return }
            retire(outgoing)
            (outgoing as? PaneContentChrome)?.onPaneHeaderHeightChange = nil
        }, ended: { [weak self] in
            // The strip, ring and corners change with the swap, in its transaction.
            guard let self else { return }
            if holdDefersStrip {
                holdDefersStrip = false
                if stripView.window != nil { stripView.sync(fromModel: true) }
            }
            guard holdKeepsStrip else { return }
            holdKeepsStrip = false
            needsLayout = true
            layoutSubtreeIfNeeded()
        })
    }

    /// Shows the strip's selection with the content: now, or at the swap of
    /// a hold that keeps the outgoing tab (no frame with the new highlight
    /// over the old tab).
    func syncStripWithContent() {
        guard stripView.window != nil else { return }
        if paintHold.kept != nil { holdDefersStrip = true } else { stripView.sync(fromModel: true) }
    }

    /// The strip's drawn height: while a hold keeps it after it hid, its
    /// shown height (the content already takes its place, unseen).
    var shownStripHeight: CGFloat {
        guard holdKeepsStrip, paintHold.kept != nil else { return stripHeight }
        return PaneChromeMetrics.current.resolvedStripHeight(scale: window?.backingScaleFactor ?? 2)
    }

    /// Ends the hold: the outgoing view goes and the incoming one shows, in one frame.
    func endPaintHold() {
        paintHold.end()
    }
}
