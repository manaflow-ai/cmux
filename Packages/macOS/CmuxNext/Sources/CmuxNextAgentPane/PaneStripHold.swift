public import AppKit
import CmuxNextWakeups

/// A new pane whose first content is a page that has not painted keeps its tab strip invisible
/// with it: the tab and its page show in one frame, never the tab first. Settings from Home's
/// dock (2026-11-16) showed its tab in a new column about 150-190 ms before its page drew.
/// A page that never reports its first frame shows its tab after ``limit``.
@MainActor
public final class PaneStripHold {
    /// The longest a tab waits for its page.
    public static let limit: Duration = .milliseconds(250)

    private weak var strip: NSView?
    private weak var page: NSView?
    private var token: UInt64 = 0
    private let deadline: DemandTimer

    public init(owner: String) {
        deadline = DemandTimer(owner: owner)
    }

    /// Whether the strip waits for its page now.
    public var holding: Bool { strip != nil }

    /// The pane shows `view`: a hold for another view ends. When `first` (the pane's first
    /// content) and `view` waits for its first frame, `strip` stays invisible until it painted or
    /// ``limit`` passed. A strip already invisible (the launch reveal holds it) is left to its holder.
    public func follow(_ view: NSView?, strip: NSView, first: Bool) {
        if page !== view { end() }
        guard first, !holding, let view, let gated = view as? PaneFirstPaintGated, gated.awaitsFirstPaint,
              strip.alphaValue > 0 else { return }
        token &+= 1
        let token = token
        self.strip = strip
        page = view
        strip.alphaValue = 0
        gated.whenFirstPainted { [weak self] in self?.end(token) }
        deadline.schedule(after: Self.limit) { @MainActor [weak self] in self?.end(token) }
    }

    /// Ends the hold (only hold `token`, when given): the strip shows, in the page's frame.
    public func end(_ token: UInt64? = nil) {
        guard let strip, token == nil || self.token == token else { return }
        self.strip = nil
        page = nil
        deadline.cancel()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strip.alphaValue = 1
        CATransaction.commit()
    }
}
