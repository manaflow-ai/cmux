public import AppKit
public import CmuxNextAgentPane
public import CmuxNextDesign

// One row on top (``PaneTabRowSharing``): the strip narrows by the content's tools; the content covers the row, under it.
extension PaneContentView {
    /// The content that may share the row: on top, in frame layout, under a strip that shows.
    private var tabRowContent: PaneTabRowSharing? {
        barPosition == .top && !isBandActive && !hidesStrip && hostsContent ? content as? PaneTabRowSharing : nil
    }
    /// Points the strip gives up beside a `shown` strip and a `tools`-wide "…" (at most half the rest).
    func tabRowToolsWidth(shown: CGFloat, tools: CGFloat) -> CGFloat {
        guard shown > 0, let width = tabRowContent?.tabRowToolsWidth, width > 0 else { return 0 }
        return min(width, max(0, (bounds.width - tools) / 2))
    }
    /// Offers the content the row (0: none); its tools' width changes lay this pane out while it is here.
    func offerTabRow(shown: CGFloat, tools: CGFloat) {
        guard hostsContent, let sharing = content as? PaneTabRowSharing else { return }
        let offers = shown > 0 && tabRowContent != nil
        sharing.onTabRowToolsChange = { [weak self, weak sharing] in
            guard let self, let sharing, sharing === self.content, self.hostsContent else { return }
            self.needsLayout = true
        }
        sharing.setTabRow(height: offers ? shown : 0, trailingInset: offers ? tools : 0)
    }
}

extension AgentPaneView: PaneTabRowSharing {
    public var tabRowToolsWidth: CGFloat? { model.tabRow.sharedWidth(zoom: webView.pageZoom) }
    public var onTabRowToolsChange: (() -> Void)? { get { model.tabRow.onChange } set { model.tabRow.onChange = newValue } }
    public func setTabRow(height: CGFloat, trailingInset: CGFloat) { AgentPaneTabRow.offer(points: height, trailingInset: trailingInset, to: self) }
}
