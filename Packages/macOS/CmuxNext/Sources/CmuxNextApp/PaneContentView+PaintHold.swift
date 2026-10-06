import AppKit
import CmuxNextAgentPane

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

/// The outgoing view a pane keeps on screen while the incoming one, above it
/// and invisible, has not painted.
struct PanePaintHold {
    /// The longest the outgoing view stays: a page that never reports its
    /// first frame shows as it is after this.
    static let limit: Duration = .milliseconds(500)

    weak var outgoing: NSView?
    weak var incoming: NSView?
    let token: UInt64
}

extension PaneContentView {
    /// Whether `view` replacing `hosted` waits for its first frame.
    func holdsForFirstPaint(_ view: NSView?, replacing hosted: NSView?) -> Bool {
        guard let hosted, let view, hosted !== view else { return false }
        return (view as? PaneFirstPaintGated)?.awaitsFirstPaint == true
    }

    /// `incoming` (installed above `outgoing`) stays invisible until it paints
    /// or ``PanePaintHold/limit`` passes; `outgoing` stays shown until then.
    func beginPaintHold(outgoing: NSView, incoming: NSView) {
        guard let gated = incoming as? PaneFirstPaintGated else { return }
        paintHoldCounter &+= 1
        let token = paintHoldCounter
        paintHold = PanePaintHold(outgoing: outgoing, incoming: incoming, token: token)
        if incoming.superview === contentHost {
            contentHost.addSubview(incoming, positioned: .above, relativeTo: outgoing)
        }
        incoming.alphaValue = 0
        gated.whenFirstPainted { [weak self] in self?.endPaintHold(token) }
        // task-owner: the hold's deadline; a later hold or show ends this one by token
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: PanePaintHold.limit)
            self?.endPaintHold(token)
        }
    }

    /// Ends the hold (only hold `token`, when given): the outgoing view goes
    /// and the incoming one shows, in one frame.
    func endPaintHold(_ token: UInt64? = nil) {
        guard let hold = paintHold, token == nil || hold.token == token else { return }
        paintHold = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let outgoing = hold.outgoing, outgoing.superview === contentHost, outgoing !== content {
            outgoing.removeFromSuperview()
            (outgoing as? PaneContentChrome)?.onPaneHeaderHeightChange = nil
        }
        hold.incoming?.alphaValue = 1
        CATransaction.commit()
    }
}
