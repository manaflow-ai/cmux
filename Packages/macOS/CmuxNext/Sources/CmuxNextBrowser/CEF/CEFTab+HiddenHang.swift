import Foundation

/// A hidden page whose renderer stays hung is ended and reloads when next shown (``BrowserHiddenHangBound``).
extension CEFTab {
    /// Whether the person sees this page now: its pane shows it and the content lifecycle did not hide it.
    var isOnScreenForHang: Bool { host.visibleTab === self && !isContentHidden }

    /// The page's hang state or visibility changed: arms or cancels the hidden-hang bound.
    func hiddenHangChanged() {
        let hung = !isClosed && browserID != nil && state.isUnresponsive && state.processExit == nil
        hiddenHangBound.update(unresponsive: hung, shown: isOnScreenForHang)
    }

    /// Whether the bound may end this page's renderer now: the page is still hung and hidden, and no
    /// page on screen shares the renderer (that page shows the card, and the person answers it).
    var mayEndHiddenHungRenderer: Bool {
        guard !isClosed, browserID != nil, state.isUnresponsive, state.processExit == nil, !isOnScreenForHang else { return false }
        guard case .chromiumRendererClients(let mine) = contentProcesses else { return true }
        let renderers = Set(mine)
        return !runtime.tabsByBrowser.values.contains { other in
            guard other !== self, !other.isClosed, other.isOnScreenForHang,
                  case .chromiumRendererClients(let theirs) = other.contentProcesses else { return false }
            return !renderers.isDisjoint(with: theirs)
        }
    }

    /// Ends the hung renderer as the card's Exit page would (the sad tab follows, then one reload on the next show).
    func endHiddenHungRenderer() {
        guard let browserID else { return }
        runtime.logger.error("hidden page unresponsive tab=\(self.id.rawValue, privacy: .public): ending its renderer, reload owed")
        rendererEndedForHang = true
        // 0: Chromium holds no hang callback now (it answered meanwhile); nothing ends.
        if runtime.shim?.unresponsiveReply(browserID, 1) != 1 { rendererEndedForHang = false }
    }
}
