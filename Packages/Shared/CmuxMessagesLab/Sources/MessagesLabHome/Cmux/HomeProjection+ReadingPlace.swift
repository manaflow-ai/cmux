import CmuxHomeCore
import CoreGraphics

/// Where a chat opens (#27627). Home makes a new transcript view for each chat it shows (a Chief
/// switch, a click in the list), so the place lives in the store's per-conversation scroll anchor
/// (`HomeStore.scrollAnchor(for:)`, kept with the drafts): a closing view keeps it, the next view of
/// the chat reads it. As in Messages, a chat left at its newest message opens at its newest message,
/// with whatever came meanwhile; a chat left scrolled up opens on the message the person was reading.
extension HomeProjection {
    /// The view closes: its place goes to the store (none at the newest message). A view never placed
    /// (closed before it had a size or its rows) leaves the kept place as it was.
    func keepReadingPlace() {
        guard !stopped, !placesOnOpen, let demo = controller.demo, demo.bounds.height > 0 else { return }
        // A message the store names (a running reply's stream or my unlogged send is not one yet).
        var ids: [ID: MessageID] = [:]
        for item in shown { if let id = item.messageID { ids[HomeMapping.id(item, aliases: aliases)] = id } }
        guard let place = demo.readingPlace(keeps: { ids[$0] != nil }), let id = ids[place.message] else {
            homeStore.setScrollAnchor(nil, for: conversation)
            return
        }
        homeStore.setScrollAnchor(HomeScrollAnchor(message: id, offset: Double(place.offset)), for: conversation)
    }

    /// The transcript has been laid out at its pane's size (not the controller's fixture size from
    /// before the host's first layout, nor a zero frame).
    private var laidOutInPane: Bool {
        let host = controller.host
        guard let pane = host.superview, let demo = controller.demo, host.bounds.height > 0 else { return false }
        return host.frame.size == pane.bounds.size && demo.frame.size == host.bounds.size
    }

    /// Once the view is laid out in its pane and has its rows: the kept place, else the newest
    /// message. Once per view. A permalink being opened (`reveal`) opens at the newest message, as
    /// before; its thread or message is the reveal's.
    func placeOnOpen() {
        guard placesOnOpen, !stopped, let demo = controller.demo, !shown.isEmpty, laidOutInPane else { return }
        placesOnOpen = false
        defer { reportReadIfNeeded() }
        if pendingReveal == nil, !revealedBeforePlacing, let anchor = homeStore.scrollAnchor(for: conversation),
           let item = shown.last(where: { $0.messageID == anchor.message }) {
            let place = (message: HomeMapping.id(item, aliases: aliases), offset: CGFloat(anchor.offset))
            if demo.show(message: place.message, offset: place.offset, in: controller.host.scrollView) {
                // Rows laid out at another width keep estimates until the width's measure lands.
                if demo.hasEstimatedRows { openedPlace = place }
                return
            }
        }
        // The newest message, whatever the open's layout passes did to the offset on the way here.
        demo.pinToBottom()
        controller.host.scrollView.syncFromModel()
    }

    /// Back at the newest message (a scroll down, a send): the kept place goes now, not only when the
    /// view closes, so a quit or a crash, which closes no view, leaves no stale place in the Home cache.
    func forgetPlaceAtNewest() {
        guard !placesOnOpen, !stopped, let state = controller.store?.state, state.ui.scroll.pinnedToBottom, state.atNewest else { return }
        homeStore.setScrollAnchor(nil, for: conversation)  // no write when there is none
    }

    /// The width's measure replaced estimated rows; it keeps the first visible row in place, which
    /// moves the message the view opened at by the rows' error in between: it goes back to its place.
    func placeAgainAfterMeasure() {
        guard let place = openedPlace, !stopped, let demo = controller.demo else { return }
        // A send or a jump to the newest message since the open pinned it: that wins.
        guard controller.store?.state.ui.scroll.pinnedToBottom != true else { openedPlace = nil; return }
        demo.show(message: place.message, offset: place.offset, in: controller.host.scrollView)  // scrolled() clears it
        openedPlace = demo.hasEstimatedRows ? place : nil
    }
}
