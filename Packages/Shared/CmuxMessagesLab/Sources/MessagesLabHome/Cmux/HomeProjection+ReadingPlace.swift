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
        guard let place = demo.readingPlace,
              let id = shown.last(where: { HomeMapping.id($0, aliases: aliases) == place.message })?.messageID else {
            homeStore.setScrollAnchor(nil, for: conversation)
            return
        }
        homeStore.setScrollAnchor(HomeScrollAnchor(message: id, offset: Double(place.offset)), for: conversation)
    }

    /// Once the view has its pane's size and its rows: the kept place, else the newest message. Once
    /// per view; a permalink being opened (`reveal`) places the view itself.
    func placeOnOpen() {
        guard placesOnOpen, !stopped, let demo = controller.demo, demo.bounds.height > 0, !shown.isEmpty else { return }
        placesOnOpen = false
        guard pendingReveal == nil else { return }
        if let anchor = homeStore.scrollAnchor(for: conversation),
           let item = shown.last(where: { $0.messageID == anchor.message }) {
            let place = (message: HomeMapping.id(item, aliases: aliases), offset: CGFloat(anchor.offset))
            if demo.show(message: place.message, offset: place.offset, in: controller.host.scrollView) {
                // A view opened at zero size laid its rows out at another width: estimates until measured.
                if demo.hasEstimatedRows { openedPlace = place }
                return
            }
        }
        // The newest message, whatever the open's layout passes did to the offset on the way here.
        demo.pinToBottom()
        controller.host.scrollView.syncFromModel()
    }

    /// The width's measure replaced estimated rows; it keeps the first visible row in place, which
    /// moves the message the view opened at by the rows' error in between: it goes back to its place.
    func placeAgainAfterMeasure() {
        guard let place = openedPlace, !stopped, let demo = controller.demo else { return }
        demo.show(message: place.message, offset: place.offset, in: controller.host.scrollView)  // scrolled() clears it
        openedPlace = demo.hasEstimatedRows ? place : nil
    }
}
