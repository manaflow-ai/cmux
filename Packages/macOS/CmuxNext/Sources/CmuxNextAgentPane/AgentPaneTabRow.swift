public import CoreGraphics
public import CmuxNextDesign
import CmuxNextSettings

/// A chat's header tools in its pane's tab row (`ChromeTunables.tabRowTools`, header/tabRow.ts):
/// the width the page last reported for them (`pane.tabRowTools {width}`, CSS pixels) and the row
/// last offered to the page (the `tabRow` event, CSS pixels; height 0 ends the page's one-row
/// mode). Kept on the model: ``AgentPaneView`` is at its size limit.
@MainActor public final class AgentPaneTabRow {
    /// The page's tools' width in CSS pixels, gap included; 0 while it draws no tools in the row.
    public private(set) var toolsWidth: CGFloat = 0
    /// Called when ``toolsWidth`` changes, or the page loads again (the pane lays out again).
    public var onChange: (() -> Void)?
    /// The row last pushed to the page, nil before the first.
    private(set) var offered: (height: CGFloat, trailingInset: CGFloat)?

    /// The page reported its tools' width.
    func report(width: CGFloat) {
        guard width != toolsWidth else { return }
        toolsWidth = width
        onChange?()
    }

    /// The page loaded again (its handshake): it draws no tools in the row and was offered none,
    /// so the pane's next layout offers the row again.
    func pageLoaded() {
        guard offered != nil || toolsWidth != 0 else { return }
        offered = nil
        toolsWidth = 0
        onChange?()
    }

    /// The `tabRow` event for the row last offered (a page that subscribes again gets it first).
    var event: AgentPageEvent { .tabRow(height: offered?.height ?? 0, trailingInset: offered?.trailingInset ?? 0) }

    /// The tools' width in points at `zoom` (points per CSS pixel); nil while the setting is off or
    /// the page draws no tools in the row.
    public func sharedWidth(zoom: CGFloat) -> CGFloat? {
        guard ChromeTunables.tabRowTools.value, toolsWidth > 0 else { return nil }
        return toolsWidth * max(0.25, zoom)
    }

    /// Offers `view`'s page the top `height` points of the pane, less `trailingInset` at the trailing
    /// end (0, or the setting off: no row), converted to CSS pixels; pushed only when it changed.
    public static func offer(points height: CGFloat, trailingInset: CGFloat, to view: AgentPaneView) {
        let zoom = max(0.25, view.webView.pageZoom)
        let on = ChromeTunables.tabRowTools.value && height > 0
        let row = view.model.tabRow
        let next = (height: on ? height / zoom : 0, trailingInset: on ? max(0, trailingInset) / zoom : 0)
        guard row.offered.map({ $0 != next }) ?? (next.height > 0) else { return }
        row.offered = next
        let event = row.event
        view.deliver([event], scripts: ["window.cmuxAcpmuxBridge?.applyTabRow?.(\(event.value.compactText));"])
    }
}

extension AgentPageEvent {
    /// The tab row the chat header's tools may sit in (`tabRow`): `{height, trailingInset}`.
    static func tabRow(height: CGFloat, trailingInset: CGFloat) -> AgentPageEvent {
        AgentPageEvent(kind: "tabRow", value: ["height": .number(Double(height)), "trailingInset": .number(Double(trailingInset))])
    }
}

/// A chat's header tools share its pane's tab row (the conformance is the App's, PaneContentView+Parking).
extension PaneTabRowSharing where Self: AgentPaneView {
    public var tabRowToolsWidth: CGFloat? { model.tabRow.sharedWidth(zoom: webView.pageZoom) }
    public var onTabRowToolsChange: (() -> Void)? { get { model.tabRow.onChange } set { model.tabRow.onChange = newValue } }
    public func setTabRow(height: CGFloat, trailingInset: CGFloat) { AgentPaneTabRow.offer(points: height, trailingInset: trailingInset, to: self) }
}
