import AppKit
import CmuxNextDesign

/// The sidebar-level notification surfaces (`SidebarNotificationEmphasis`): the inbox shelf at the top of
/// the list, the arrival card at its bottom, and the loud-rows look's edge beacons. Each floats over the
/// list (the list's scroll range grows by a shelf's height), so a row never moves when one shows.
@MainActor
final class SidebarAttentionSurfaces {
    let inbox = SidebarAttentionShelfView(role: .inbox)
    let arrival = SidebarAttentionShelfView(role: .arrival)
    let above = SidebarAttentionBeaconView(edge: .top)
    let below = SidebarAttentionBeaconView(edge: .bottom)
    /// Coalesces a burst of row patches (status ticks) into one pass.
    let refresh = DemandTimer(owner: "sidebar.attention.refresh")
    var arrivals = SidebarArrivals()
    var items: [SidebarAttentionItem] = []
    var look = SidebarNotificationEmphasis.standard
}

extension SidebarView {
    func buildAttention() {
        let surfaces = attention
        [surfaces.inbox, surfaces.arrival, surfaces.above, surfaces.below].forEach(addSubview)
        let open: (WorkspaceID) -> Void = { [weak self] id in self?.openAttention(id) }
        surfaces.inbox.onOpen = open
        surfaces.arrival.onOpen = open
        surfaces.arrival.onDismiss = { [weak self] in
            guard let self else { return }
            attention.arrivals.dismiss()
            refreshAttention()
        }
        surfaces.above.onClick = { [weak self] in self?.revealBeacon(.top) }
        surfaces.below.onClick = { [weak self] in self?.revealBeacon(.bottom) }
        let previousPatch = model.onRowsPatchedWithPrevious
        model.onRowsPatchedWithPrevious = { [weak self] changes in
            previousPatch?(changes)
            guard let self, changes.contains(where: { WorkspaceRowAttention($0.before) != WorkspaceRowAttention($0.after) }) else { return }
            attention.refresh.scheduleIfIdle(after: .milliseconds(50)) { @MainActor [weak self] in self?.refreshAttention() }
        }
    }

    /// Goes to a workspace from a shelf: its row shown (folds opened, scrolled to, flashed), then opened.
    func openAttention(_ id: WorkspaceID) {
        _ = revealWorkspace(id)
        model.click(id)
    }

    /// Recomputes what has a notification, the arrival queue and every surface for the current look.
    func refreshAttention() {
        let surfaces = attention
        let look = SidebarNotificationEmphasis.tunable.value
        let items = SidebarAttentionItem.all(in: model.sections)
        let arrived = surfaces.arrivals.update(items)
        surfaces.look = look
        surfaces.items = items
        let before = (surfaces.inbox.preferredHeight, surfaces.arrival.preferredHeight)
        surfaces.inbox.show(look == .inbox ? items : [])
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        surfaces.arrival.show(look == .arrivalCard ? surfaces.arrivals.queue.compactMap { byID[$0] } : [])
        // A new notification's row flashes where it is, when it is drawn (the card says which, wherever it is).
        if look == .arrivalCard {
            for id in arrived {
                if let row = list.displayed.row(for: .workspace(id)) { list.flashRevealed(row) }
            }
        }
        if (surfaces.inbox.preferredHeight, surfaces.arrival.preferredHeight) != before { needsLayout = true }
        updateAttentionBeacons()
    }

    /// The loud-rows look's beacons: how many rows with a notification lie above and below the visible part of the list.
    func updateAttentionBeacons() {
        let surfaces = attention
        guard surfaces.look == .loudRows else {
            surfaces.above.show(count: 0, kind: nil)
            surfaces.below.show(count: 0, kind: nil)
            return
        }
        let clip = scrollView.contentView, insets = scrollView.contentInsets
        let top = clip.bounds.minY + insets.top, bottom = clip.bounds.maxY - insets.bottom
        var above: [WorkspaceRowAttention.Kind] = [], below: [WorkspaceRowAttention.Kind] = []
        for item in surfaces.items {
            guard let row = list.displayed.row(for: .workspace(item.id)) else { continue }
            let frame = list.frame(for: row)
            if frame.midY < top { above.append(item.attention.kind) } else if frame.midY > bottom { below.append(item.attention.kind) }
        }
        let before = (surfaces.above.isHidden, surfaces.below.isHidden, surfaces.above.count, surfaces.below.count)
        surfaces.above.show(count: above.count, kind: above.min())
        surfaces.below.show(count: below.count, kind: below.min())
        if (surfaces.above.isHidden, surfaces.below.isHidden, surfaces.above.count, surfaces.below.count) != before { needsLayout = true }
    }

    /// Scrolls to the nearest row with a notification past `edge` and flashes it.
    private func revealBeacon(_ edge: SidebarAttentionBeaconView.Edge) {
        let clip = scrollView.contentView, insets = scrollView.contentInsets
        let top = clip.bounds.minY + insets.top, bottom = clip.bounds.maxY - insets.bottom
        let candidates = attention.items.compactMap { item -> (WorkspaceID, CGFloat)? in
            guard let row = list.displayed.row(for: .workspace(item.id)) else { return nil }
            return (item.id, list.frame(for: row).midY)
        }
        let target = edge == .top ? candidates.filter { $0.1 < top }.max { $0.1 < $1.1 } : candidates.filter { $0.1 > bottom }.min { $0.1 < $1.1 }
        if let target { _ = list.revealRow(target.0, centre: true) }
    }

    /// The shelves over `listFrame` (inbox at its top, arrival card above the needs-you tray at its bottom) and the
    /// beacons at its edges; returns the bottom inset the arrival card needs. The list's top inset makes room for the inbox.
    func layoutAttention(over listFrame: NSRect, bottomTaken: CGFloat) -> CGFloat {
        let surfaces = attention, inset = Metrics.space2
        let inboxHeight = isEditingItems ? 0 : surfaces.inbox.preferredHeight
        surfaces.inbox.frame = NSRect(x: listFrame.minX + inset, y: listFrame.minY + (inboxHeight > 0 ? inset : 0),
                                      width: max(0, listFrame.width - 2 * inset), height: inboxHeight)
        let top = inboxHeight > 0 ? inboxHeight + 2 * inset : 0
        if scrollView.contentInsets.top != top { scrollView.contentInsets.top = top }
        let cardHeight = isEditingItems ? 0 : surfaces.arrival.preferredHeight
        surfaces.arrival.frame = NSRect(x: listFrame.minX + inset, y: listFrame.maxY - bottomTaken - cardHeight - (cardHeight > 0 ? inset : 0),
                                        width: max(0, listFrame.width - 2 * inset), height: cardHeight)
        for beacon in [surfaces.above, surfaces.below] where !beacon.isHidden {
            let size = beacon.preferredSize
            let y = beacon.edge == .top ? listFrame.minY + top + inset : listFrame.maxY - bottomTaken - size.height - inset
            beacon.frame = NSRect(x: listFrame.midX - size.width / 2, y: y, width: size.width, height: size.height)
        }
        return cardHeight > 0 ? cardHeight + inset : 0
    }
}
