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
    /// The last positive ``toolsWidth``, kept after the row ends or the page loads again: whether
    /// the tools fit a pane's row (`PaneTabRowSharing.fitsTabRow`); 0 before the page first reported.
    public private(set) var neededWidth: CGFloat = 0
    /// Called when ``toolsWidth`` changes, or the page loads again (the pane lays out again).
    public var onChange: (() -> Void)?
    /// The row last pushed to the page, nil before the first.
    private(set) var offered: (height: CGFloat, trailingInset: CGFloat)?
    private var offeredNativeRowTools: Bool?
    /// Only a shared page host has the return event stream needed by native controls.
    var supportsNativeTools = false
    public var nativeToolsEnabled: Bool { supportsNativeTools && ChromeTunables.nativeRowTools.value }

    /// The page reported its tools' width.
    func report(width: CGFloat) {
        if width > 0 { neededWidth = width }
        guard width != toolsWidth else { return }
        toolsWidth = width
        onChange?()
    }

    /// The page loaded again (its handshake): it draws no tools in the row and was offered none,
    /// so the pane's next layout offers the row again.
    func pageLoaded() {
        guard offered != nil || toolsWidth != 0 else { return }
        offered = nil
        offeredNativeRowTools = nil
        toolsWidth = 0
        onChange?()
    }

    /// The `tabRow` event for the row last offered (a page that subscribes again gets it first).
    var event: AgentPageEvent { .tabRow(height: offered?.height ?? 0, trailingInset: offered?.trailingInset ?? 0, nativeRowTools: offeredNativeRowTools ?? false) }

    /// The tools' width in points at `zoom` (points per CSS pixel); nil while the setting is off or
    /// the page draws no tools in the row.
    public func sharedWidth(zoom: CGFloat) -> CGFloat? {
        guard ChromeTunables.tabRowTools.value, toolsWidth > 0 else { return nil }
        return toolsWidth * max(0.25, zoom)
    }

    /// ``neededWidth`` in points at `zoom`; nil while the setting is off or before the page reported.
    public func sharedNeed(zoom: CGFloat) -> CGFloat? {
        guard ChromeTunables.tabRowTools.value, neededWidth > 0 else { return nil }
        return neededWidth * max(0.25, zoom)
    }

    /// Offers `view`'s page the top `height` points of the pane, less `trailingInset` at the trailing
    /// end (0, or the setting off: no row), converted to CSS pixels; pushed only when it changed.
    public static func offer(points height: CGFloat, trailingInset: CGFloat, to view: AgentPaneView) {
        let zoom = max(0.25, view.webView.pageZoom)
        let on = ChromeTunables.tabRowTools.value && height > 0
        let nativeRowTools = view.model.tabRow.nativeToolsEnabled
        let row = view.model.tabRow
        let next = (height: on ? height / zoom : 0, trailingInset: on ? max(0, trailingInset) / zoom : 0)
        let shares = on && row.toolsWidth > 0
        view.setTabRowCover(shares ? height : 0) // the pane lays the view under the strip only then
        if let page = view.page {
            // A Chromium chat is a window above the pane: it leaves the pane's tabs and toolbar uncovered.
            // The holes are worked out from the row's top-left corner; the chat view is not flipped, so
            // its top is maxY (at y 0 they cut the composer's footer out of the page instead).
            let top = view.isFlipped ? view.bounds.minY : view.bounds.maxY - height
            let holes = shares ? nativeHoles(width: view.bounds.width, height: height, trailingInset: max(0, trailingInset),
                                             tools: row.sharedWidth(zoom: zoom) ?? 0) : []
            page.nativeRects = holes.map { page.convert($0.offsetBy(dx: view.bounds.minX, dy: top), from: view) }
        }
        guard row.offered.map({ $0 != next || row.offeredNativeRowTools != nativeRowTools }) ?? (next.height > 0 || nativeRowTools) else { return }
        row.offered = next
        row.offeredNativeRowTools = nativeRowTools
        let event = row.event
        view.deliver([event], scripts: ["window.cmuxAcpmuxBridge?.applyTabRow?.(\(event.value.compactText));"])
    }
}

/// The parts of a shared tab row `width` points wide and `height` tall (top-left origin) that the
/// pane's native chrome draws: its tabs, from the leading edge to where the chat's `tools` begin
/// (the strip gives up at most half its room, `PaneTabRowSharing.tabRowWidth`), and its toolbar in
/// the trailing `trailingInset` points.
private func nativeHoles(width: CGFloat, height: CGFloat, trailingInset: CGFloat, tools: CGFloat) -> [CGRect] {
    let room = max(0, width - trailingInset)
    let span = min(max(0, tools), room / 2)
    return [CGRect(x: 0, y: 0, width: room - span, height: height),
            CGRect(x: room, y: 0, width: width - room, height: height)].filter { !$0.isEmpty }
}

extension AgentPageEvent {
    /// The tab row the chat header's tools may sit in (`tabRow`): `{height, trailingInset}`.
    static func tabRow(height: CGFloat, trailingInset: CGFloat, nativeRowTools: Bool) -> AgentPageEvent {
        AgentPageEvent(kind: "tabRow", value: ["height": .number(Double(height)), "trailingInset": .number(Double(trailingInset)), "nativeRowTools": .bool(nativeRowTools)])
    }
}

/// A chat's header tools share its pane's tab row (the conformance is the App's, PaneContentView+Parking).
extension PaneTabRowSharing where Self: AgentPaneView {
    public var tabRowToolsWidth: CGFloat? { model.tabRow.sharedWidth(zoom: webView.pageZoom) }
    public var tabRowToolsNeed: CGFloat? { model.tabRow.sharedNeed(zoom: webView.pageZoom) }
    public var onTabRowToolsChange: (() -> Void)? { get { model.tabRow.onChange } set { model.tabRow.onChange = newValue } }
    public func setTabRow(height: CGFloat, trailingInset: CGFloat) { AgentPaneTabRow.offer(points: height, trailingInset: trailingInset, to: self) }
}
