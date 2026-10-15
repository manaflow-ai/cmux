import AppKit
import CmuxNextAgentPane
import CmuxNextDesign

// One row on top (`ChromeTunables.tabRowTools`; Leo 2026-10-14, "why is there even a top bar"):
// content that draws its own tools in the pane's tab row (``PaneTabRowSharing``, a chat's header
// tools) gets the strip's row too, and the strip gives up the tools' width at its trailing end,
// left of the pane's "…". The strip and "…" were added after the content host, so they stay above
// the content in the row; the strip's own sizing is untouched, it only gets a narrower frame.
extension PaneContentView {
    /// The content that may share the row: on top, in frame layout, under a strip that shows.
    private var tabRowContent: PaneTabRowSharing? {
        guard barPosition == .top, !isBandActive, !hidesStrip, hostsContent else { return nil }
        return content as? PaneTabRowSharing
    }

    /// Points the strip gives up for the content's tools beside a strip `shown` tall with "…"
    /// `tools` wide; 0 keeps today's layout (the content below the strip).
    func tabRowToolsWidth(shown: CGFloat, tools: CGFloat) -> CGFloat {
        guard shown > 0, let width = tabRowContent?.tabRowToolsWidth, width > 0 else { return 0 }
        return min(width, max(0, (bounds.width - tools) / 2))
    }

    /// Where the content shows below the strip: the strip's bottom while the content covers its
    /// row too, else the content host's top (the agent name tag stays out of the row).
    var contentTopBelowStrip: CGFloat {
        let host = contentHost.frame
        guard barPosition == .top, !isBandActive, !stripView.isHidden, host.minY < stripView.frame.maxY else { return host.minY }
        return stripView.frame.maxY
    }

    /// Tells the hosted content the row it may draw in (0 when it may not): it shows or ends its
    /// tools there, and reports their width (``PaneTabRowSharing/onTabRowToolsChange``).
    func offerTabRow(shown: CGFloat, tools: CGFloat) {
        // A view another pane took gets its row from that pane.
        guard hostsContent, let content = content as? PaneTabRowSharing else { return }
        let offers = shown > 0 && tabRowContent != nil
        content.setTabRow(height: offers ? shown : 0, trailingInset: offers ? tools : 0)
    }

    /// The content's tools width changed: lay out again, if it is still this pane's content.
    func followTabRow(_ view: NSView?) {
        guard let sharing = view as? PaneTabRowSharing else { return }
        sharing.onTabRowToolsChange = { [weak self, weak view] in
            guard let self, let view, view === self.content, self.hostsContent else { return }
            self.needsLayout = true
        }
    }

    /// `view` leaves this pane: it no longer reports to it.
    func unfollowTabRow(_ view: NSView?) {
        (view as? PaneTabRowSharing)?.onTabRowToolsChange = nil
    }
}

/// A chat's header tools (header/tabRow.ts): the page reports their width (`pane.tabRowTools`) and
/// draws them in the row the pane offers (`tabRow`), in CSS pixels, so both convert through the
/// page's zoom. Off with `ChromeTunables.tabRowTools`: no width, and the page is offered no row.
extension AgentPaneView: PaneTabRowSharing {
    public var tabRowToolsWidth: CGFloat? {
        guard ChromeTunables.tabRowTools.value else { return nil }
        let width = model.tabRow.toolsWidth * pageZoomForTabRow
        return width > 0 ? width : nil
    }

    public var onTabRowToolsChange: (() -> Void)? {
        get { model.tabRow.onChange }
        set { model.tabRow.onChange = newValue }
    }

    public func setTabRow(height: CGFloat, trailingInset: CGFloat) {
        let on = ChromeTunables.tabRowTools.value && height > 0
        let zoom = pageZoomForTabRow
        AgentPaneTabRow.offer(height: on ? height / zoom : 0, trailingInset: on ? trailingInset / zoom : 0, to: self)
    }

    /// Points per CSS pixel (the UI scale times the pane's zoom), never 0.
    private var pageZoomForTabRow: CGFloat { max(0.25, webView.pageZoom) }
}
