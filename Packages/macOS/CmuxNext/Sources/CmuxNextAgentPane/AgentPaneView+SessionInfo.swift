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
        model.sessionInfo.onOverlays = { [weak self] in self?.applySessionInfoOverlays() }
        // task-owner: lives as long as the view, cancelled in close(); event-driven (Observation)
        model.sessionInfo.hostObservation = Task { [weak self] in
            for await on in ObservationStream({ AgentPaneTunables.nativeSessionInfo.value }) {
                guard let self else { return }
                // Compared with what the loaded page was last told, so a flip before this first
                // runs is not lost; a page not loaded yet hears it in its load replay.
                if let told = self.model.sessionInfo.announced, told != on { self.announceSessionInfo() }
                self.applySessionInfo()
            }
        }
    }

    /// Tells a loaded page whether the App draws Session Info (its load and `ready` replays).
    func announceSessionInfo() {
        let on = drawsSessionInfo
        model.sessionInfo.announced = on
        deliver([.sessionInfoHost(on)], scripts: [AgentPaneSessionInfo.hostScript(on)])
    }

    /// Makes, updates or removes the panel for the page's last model.
    func applySessionInfo() {
        let holder = model.sessionInfo
        guard drawsSessionInfo, let info = holder.info, info.open else {
            if let panel = holder.panel {
                // The keyboard was in the panel (a click there, then Esc): it goes back to the chat,
                // as the page's Esc gave it to the toggle, not to nothing.
                let hadFocus = (window?.firstResponder as? NSView)?.isDescendant(of: panel) == true
                panel.removeFromSuperview()
                if hadFocus { focusChat() }
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
            self?.forwardSessionInfoAction(id)
        }
        store.sendWithRect = { [weak self] id, paneRect in
            guard let self else { return }
            let pageRect: CGRect?
            if let paneRect {
                let target: NSView = self.page ?? self.webView
                pageRect = Self.sessionInfoPageRect(target.convert(paneRect, from: self),
                                                    bounds: target.bounds, flipped: target.isFlipped,
                                                    zoom: CGFloat(self.uiPointerPageZoom))
            } else {
                pageRect = nil
            }
            self.forwardSessionInfoAction(id, rect: pageRect)
        }
        store.relayout = { [weak self] in self?.layoutSessionInfo() }
        let panel = AgentPaneSessionInfoPanel(store: store)
        store.rectForView = { [weak self, weak panel] view in
            guard let self, let panel else { return nil }
            let rect = panel.convert(view.bounds, from: view)
            return self.convert(rect, from: panel)
        }
        // Above the page and the loading cover, under nothing else the pane draws.
        addSubview(panel, positioned: .above, relativeTo: page ?? webView)
        model.sessionInfo.panel = panel
        return panel
    }

    /// Native keyboard and menu choices carry the same person-input witness as page choices.
    /// The existing check refuses scripted input and calls made outside a current person event.
    func forwardSessionInfoAction(_ id: String, rect: CGRect? = nil, event: NSEvent? = NSApp.currentEvent) {
        AgentPanePersonInput.record(model.transport.gestures, sources: eventSources, event: event)
        deliver([.sessionInfoAction(id, rect: rect)], scripts: [AgentPaneSessionInfo.actionScript(id, rect: rect)])
    }

    /// The pane's theme changed: the panel's ink follows.
    func themeSessionInfo(_ tokens: ThemeTokens) {
        model.sessionInfo.panel?.store.colors = AgentPaneSessionInfoColors(tokens)
    }

    /// Lays the panel out in the page's frame: the page's width from its right edge (less a side
    /// panel's width and the 8 px float margin), from `top` under the header, as tall as its content
    /// up to the page's foot.
    func layoutSessionInfo() {
        guard let panel = model.sessionInfo.panel, let info = panel.store.info else { return }
        let zoom = max(0.25, CGFloat(uiPointerPageZoom))
        panel.store.zoom = zoom
        let frame = Self.sessionInfoFrame(page: page?.frame ?? webView.frame, info: info,
                                          width: panel.store.width, zoom: zoom, flipped: isFlipped,
                                          content: { [weak panel] width in panel?.fittingHeight(forWidth: width) ?? .greatestFiniteMagnitude })
        if panel.frame != frame { panel.frame = frame }
        applySessionInfoOverlays()
    }

    /// Cuts the page's open popups out of the panel (``AgentPaneSessionInfoOverlay``): the panel steps
    /// behind each one where they overlap and is whole again when they close.
    func applySessionInfoOverlays() {
        guard let panel = model.sessionInfo.panel else { return }
        let zoom = max(0.25, CGFloat(uiPointerPageZoom))
        let page = page?.frame ?? webView.frame
        panel.holes = model.sessionInfo.overlays.compactMap { overlay in
            let pane = Self.sessionInfoOverlayRect(overlay.rect, page: page, zoom: zoom, flipped: isFlipped)
            let rect = panel.convert(pane, from: self)
            return rect.intersects(panel.bounds) ? AgentPaneSessionInfoOverlay(rect: rect, radius: overlay.radius * zoom) : nil
        }
        applyNativeRects()
    }

    /// A popup's viewport rect (top-left CSS pixels) in pane coordinates, for a page frame `page`.
    static func sessionInfoOverlayRect(_ rect: CGRect, page: CGRect, zoom: CGFloat, flipped: Bool) -> CGRect {
        let scale = max(0.25, zoom)
        let x = page.minX + rect.minX * scale
        let y = flipped ? page.minY + rect.minY * scale : page.maxY - rect.maxY * scale
        return CGRect(x: x, y: y, width: rect.width * scale, height: rect.height * scale)
    }

    /// Converts a row anchor from its host view to top-left page CSS pixels in either page engine.
    static func sessionInfoPageRect(_ rect: CGRect, bounds: CGRect, flipped: Bool, zoom: CGFloat) -> CGRect {
        let scale = max(0.25, zoom)
        let top = flipped ? rect.minY - bounds.minY : bounds.maxY - rect.maxY
        return CGRect(x: (rect.minX - bounds.minX) / scale, y: top / scale,
                      width: rect.width / scale, height: rect.height / scale)
    }

    /// The panel's frame in the pane for `info` in a page frame `page` (pane coordinates). Its top
    /// is under the header; it is `content`'s height at its width (points), up to the room above
    /// the foot, so it never runs past its last section. With no `content` it takes the whole room.
    static func sessionInfoFrame(page: CGRect, info: AgentPaneSessionInfoModel, width: Double,
                                 zoom: CGFloat, flipped: Bool,
                                 content: ((CGFloat) -> CGFloat)? = nil) -> CGRect {
        let margin = AgentPaneSessionInfoModel.floatMargin * zoom
        let top = CGFloat(info.top) * zoom
        let foot = CGFloat(info.foot ?? AgentPaneSessionInfoModel.floatMargin) * zoom
        let wide = min(CGFloat(width) * zoom, max(0, page.width - 2 * margin))
        let x = max(page.minX + margin, page.maxX - CGFloat(info.side) * zoom - margin - wide)
        let room = max(0, page.height - top - foot)
        let height = min(room, max(0, (content?(wide) ?? room).rounded(.up)))
        let y = flipped ? page.minY + top : page.maxY - top - height
        return CGRect(x: x, y: y, width: wide, height: height).integral
    }

    /// A Chromium page is a window above the pane: it leaves the shared tab row's holes, the panel and
    /// the "act as me" pill uncovered, so they show and take clicks.
    func applyNativeRects() {
        guard let page else { return }
        var rects = model.tabRow.holes
        if let badge = actAsMeBadge, !badge.isHidden, !badge.bounds.isEmpty {
            rects.append(page.convert(badge.bounds, from: badge))
        }
        if let panel = model.sessionInfo.panel {
            // The panel less the page's popups over it, so Chromium draws those whole.
            rects += panel.uncoveredRects().map { page.convert($0, from: panel) }
        }
        page.nativeRects = rects
    }
}

extension AgentPaneSessionInfoModel {
    /// The page's `FLOAT_MARGIN`: the panel's inset from the pane's edges, CSS pixels.
    static let floatMargin: CGFloat = 8
}
