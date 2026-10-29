import AppKit
import CmuxNextCompat
import CmuxNextDesign

/// Session Info drawn by the App over the agent pane (``AgentPaneSessionInfo``,
/// ``AgentPaneSessionInfoPanel``). The page decides whether it shows and what it lists; the view
/// makes the panel while it shows, lays it out from the page's numbers and hands its clicks back.
extension AgentPaneView {
    /// The page hears that this App draws Session Info (`sessionInfoHost`), unless the Debug Settings
    /// toggle keeps the page's own panel.
    var drawsSessionInfo: Bool { AgentPaneTunables.nativeSessionInfo.value }

    /// Follows the page's model for as long as the view lives (called once from init), and the Debug
    /// Settings toggle: a flip tells the loaded page at once, so its own panel draws again (or stops)
    /// with no reload.
    func installSessionInfo() {
        model.sessionInfo.onChange = { [weak self] in self?.applySessionInfo() }
        // task-owner: lives as long as the view, cancelled in close(); event-driven (Observation)
        model.sessionInfo.hostObservation = Task { [weak self] in
            var shown = AgentPaneTunables.nativeSessionInfo.value
            for await on in ObservationStream({ AgentPaneTunables.nativeSessionInfo.value }) {
                guard let self else { return }
                guard on != shown else { continue }
                shown = on
                self.announceSessionInfo()
                self.applySessionInfo()
            }
        }
    }

    /// Tells a loaded page whether the App draws Session Info (its load and `ready` replays).
    func announceSessionInfo() {
        let on = drawsSessionInfo
        deliver([.sessionInfoHost(on)], scripts: [AgentPaneSessionInfo.hostScript(on)])
    }

    /// Makes, updates or removes the panel for the page's last model.
    func applySessionInfo() {
        let holder = model.sessionInfo
        guard drawsSessionInfo, let info = holder.info, info.open else {
            if let panel = holder.panel {
                panel.removeFromSuperview()
                holder.panel = nil
                applyNativeRects()
            }
            return
        }
        let panel = holder.panel ?? makeSessionInfoPanel()
        panel.store.update(info)
        panel.setAccessibilityLabel(info.label)
        layoutSessionInfo()
    }

    private func makeSessionInfoPanel() -> AgentPaneSessionInfoPanel {
        let store = AgentPaneSessionInfoStore()
        store.colors = AgentPaneSessionInfoColors(themeTokens)
        store.send = { [weak self] id in
            self?.deliver([.sessionInfoAction(id)], scripts: [AgentPaneSessionInfo.actionScript(id)])
        }
        store.relayout = { [weak self] in self?.layoutSessionInfo() }
        let panel = AgentPaneSessionInfoPanel(store: store)
        // Above the page and the loading cover, under nothing else the pane draws.
        addSubview(panel, positioned: .above, relativeTo: page ?? webView)
        model.sessionInfo.panel = panel
        return panel
    }

    /// The pane's theme changed: the panel's ink follows.
    func themeSessionInfo(_ tokens: ThemeTokens) {
        model.sessionInfo.panel?.store.colors = AgentPaneSessionInfoColors(tokens)
    }

    /// Lays the panel out in the page's frame: the page's width from its right edge (less a side
    /// panel's width and the 8 px float margin), from `top` under the header to the page's foot.
    func layoutSessionInfo() {
        guard let panel = model.sessionInfo.panel, let info = panel.store.info else { return }
        let zoom = max(0.25, webView.pageZoom)
        panel.store.zoom = zoom
        let frame = Self.sessionInfoFrame(page: page?.frame ?? webView.frame, info: info,
                                          width: panel.store.width, zoom: zoom, flipped: isFlipped)
        if panel.frame != frame { panel.frame = frame }
        applyNativeRects()
    }

    /// The panel's frame in the pane for `info` in a page frame `page` (pane coordinates).
    static func sessionInfoFrame(page: CGRect, info: AgentPaneSessionInfoModel, width: Double,
                                 zoom: CGFloat, flipped: Bool) -> CGRect {
        let margin = AgentPaneSessionInfoModel.floatMargin * zoom
        let top = CGFloat(info.top) * zoom
        let foot = CGFloat(info.foot ?? AgentPaneSessionInfoModel.floatMargin) * zoom
        let wide = min(CGFloat(width) * zoom, max(0, page.width - 2 * margin))
        let x = max(page.minX + margin, page.maxX - CGFloat(info.side) * zoom - margin - wide)
        let height = max(0, page.height - top - foot)
        let y = flipped ? page.minY + top : page.minY + foot
        return CGRect(x: x, y: y, width: wide, height: height).integral
    }

    /// A Chromium page is a window above the pane: it leaves the shared tab row's holes and the
    /// panel uncovered, so both show and take clicks.
    func applyNativeRects() {
        guard let page else { return }
        var rects = model.tabRow.holes
        if let panel = model.sessionInfo.panel { rects.append(page.convert(panel.frame, from: self)) }
        page.nativeRects = rects
    }
}

extension AgentPaneSessionInfoModel {
    /// The page's `FLOAT_MARGIN`: the panel's inset from the pane's edges, CSS pixels.
    static let floatMargin: CGFloat = 8
}
