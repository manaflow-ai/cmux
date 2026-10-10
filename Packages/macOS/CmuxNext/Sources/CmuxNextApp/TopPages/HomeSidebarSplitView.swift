import AppKit
import CmuxNextHome

/// The Home page's two columns with a real divider: the resize cursor over a
/// wide grab area, the sidebar between its minimum and half the window, a
/// double-click back to the standard width, and the width kept per window
/// (`HomeSidebarWidth`). The docked column model takes this width over when
/// the daemon owns the column.
@MainActor
final class HomeSidebarSplitView: NSSplitView, NSSplitViewDelegate {
    /// The window's key for its saved width (resolved on use: the window's
    /// id changes once when it adopts a restored record).
    var windowKey: () -> String = { "" }
    let widths: HomeSidebarWidth
    /// Half the grab area on each side of the 1 pt divider.
    static let grab: CGFloat = 4
    private var placed = false
    /// The list's own limits (MessagesLab's `minimumWidth`, `preferredWidth`).
    let minimum: CGFloat
    let standard: CGFloat

    init(sidebar: HomeSidebarView, content: NSView, widths: HomeSidebarWidth = HomeSidebarWidth()) {
        self.widths = widths
        minimum = sidebar.minimumWidth
        standard = sidebar.preferredWidth
        super.init(frame: .zero)
        isVertical = true
        dividerStyle = .thin
        addArrangedSubview(sidebar)
        addArrangedSubview(content)
        setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        delegate = self
        setAccessibilityIdentifier("cmux.home.split")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    var sidebarWidth: CGFloat { arrangedSubviews.first?.frame.width ?? 0 }

    /// The divider in window points from the content view's top-left (as
    /// `debug.mouse` takes them), nil before the view is in a window.
    var dividerFrameInWindow: NSRect? {
        guard let window else { return nil }
        let base = convert(dividerRect, to: nil)
        let height = window.contentView?.bounds.height ?? window.frame.height
        return NSRect(x: base.minX, y: height - base.maxY, width: base.width, height: base.height)
    }

    private var dividerRect: NSRect {
        NSRect(x: sidebarWidth, y: 0, width: dividerThickness, height: bounds.height)
    }

    /// The width to show now: the saved one (else the standard), clamped to this window.
    private var wantedWidth: CGFloat {
        clamp(widths.width(window: windowKey()) ?? standard)
    }

    private func clamp(_ width: CGFloat) -> CGFloat { HomeSidebarWidth.clamp(width, window: bounds.width, minimum: minimum) }

    override func layout() {
        super.layout()
        guard bounds.width > 0 else { return }
        if !placed {
            placed = true
            setPosition(wantedWidth, ofDividerAt: 0)
        } else if sidebarWidth > clamp(sidebarWidth) {
            // The window shrank: the sidebar stays within half of it (the saved width is kept).
            setPosition(clamp(sidebarWidth), ofDividerAt: 0)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2, dividerRect.insetBy(dx: -Self.grab, dy: 0).contains(point) {
            resetWidth()
            return
        }
        super.mouseDown(with: event)
    }

    /// Back to the standard width (the divider's double-click).
    func resetWidth() {
        widths.reset(window: windowKey())
        setPosition(clamp(standard), ofDividerAt: 0)
    }

    // MARK: NSSplitViewDelegate

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        minimum
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        clamp(.greatestFiniteMagnitude)
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }

    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        // A window resize goes to the transcript; the sidebar keeps its width.
        view !== arrangedSubviews.first
    }

    func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect,
                   ofDividerAt dividerIndex: Int) -> NSRect {
        drawnRect.insetBy(dx: -Self.grab, dy: 0)
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        // Only the user's drag is kept (AppKit names the divider it moved).
        guard placed, notification.userInfo?["NSSplitViewDividerIndex"] != nil else { return }
        widths.save(sidebarWidth, window: windowKey())
    }
}
