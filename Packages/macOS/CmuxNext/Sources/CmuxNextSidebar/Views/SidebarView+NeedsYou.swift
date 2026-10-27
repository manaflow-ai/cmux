import AppKit
import CmuxNextDesign

// The session tree's needs-you tray (`SidebarNeedsYou`, SidebarNeedsYouTrayView): docked at the
// bottom of the list and recomputed whenever rows change, a row patches in place, or the tree
// passes again. It never moves a row: the list's scroll range grows by its height.
extension SidebarView {
    func buildNeedsYou() {
        addSubview(needsYouTray)
        needsYouTray.onOpen = { [weak self] id in
            guard let self else { return }
            SidebarSessionTree.shared.reveal(id, lists: self.model.listsHolding(id))
            self.model.click(id)
        }
        // After the list's own patch handler: a status tick that patches one row updates the tray too,
        // once per burst (every tick walks every section and the tree order otherwise).
        let listPatch = model.onRowsPatched
        model.onRowsPatched = { [weak self] rows in
            listPatch?(rows)
            guard let self, SidebarSessionTree.shared.state != nil || self.needsYouTray.preferredHeight > 0 else { return }
            self.needsYouRefresh.scheduleIfIdle(after: .milliseconds(100)) { @MainActor [weak self] in self?.refreshNeedsYou() }
        }
    }

    func refreshNeedsYou() {
        let before = needsYouTray.preferredHeight
        needsYouTray.show(SidebarNeedsYou.make(model.sections, tree: SidebarSessionTree.shared.drawn))
        if needsYouTray.preferredHeight != before { needsLayout = true }
    }

    /// Over the bottom of `listFrame`; the list scrolls past it. Edit mode's bar takes that place, so
    /// the tray steps aside while it shows (the bar's own layout, SidebarView+EditItems).
    func layoutNeedsYou(over listFrame: NSRect) {
        let height = isEditingItems ? 0 : needsYouTray.preferredHeight, inset = Metrics.space2
        needsYouTray.frame = NSRect(x: listFrame.minX + inset, y: listFrame.maxY - height - (height > 0 ? inset : 0),
                                    width: max(0, listFrame.width - 2 * inset), height: height)
        let bottom = height > 0 ? height + 2 * inset : 0
        if scrollView.contentInsets.bottom != bottom { scrollView.contentInsets.bottom = bottom }
    }
}
