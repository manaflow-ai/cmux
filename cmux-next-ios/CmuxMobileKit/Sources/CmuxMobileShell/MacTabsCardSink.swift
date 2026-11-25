#if os(iOS)
import CmuxMobileLive
import CmuxMobileWorkspaces
import Foundation
import UIKit

/// Joins the two halves the package graph keeps apart: the feed that reads a Mac's `tabs`
/// service (CmuxMobileLive) and the store its cards read (CmuxMobileWorkspaces).
@MainActor
final class MacTabsCardSink: MacTabsSink {
    static let shared = MacTabsCardSink()
    let cards = MacTabCards.shared

    /// `feed` writes to the card store from now on, and is told which cards to fill first.
    func attach(_ feed: MacTabsFeed) {
        feed.sink = self
        Self.setViewport(on: feed)
        // The newest coordinator's feed (RootView's, or a headless reply's).
        cards.near = { [weak feed] tabIDs, macID in feed?.setNear(tabIDs, macID: macID) }
    }

    /// The grid's two-column card and the screen, in pixels (TabsKit's card: half the page
    /// less its margins, at the page's shape).
    static func setViewport(on feed: MacTabsFeed) {
        let screen = UIScreen.main
        let size = screen.bounds.size, scale = screen.scale
        let width = min(size.width, size.height), height = max(size.width, size.height)
        let cardWidth = ((width - 48) / 2).rounded(.down) * scale
        feed.setViewport(cardPixelWidth: UInt32(cardWidth.rounded()),
                         cardAspect: Double(width / max(1, height)), displayScale: Double(scale),
                         screenPixelW: UInt32((width * scale).rounded()), screenPixelH: UInt32((height * scale).rounded()))
    }

    func heldBlobs(macID: String) -> [String] { cards.heldBlobs(macID: macID) }

    func save(_ bytes: Data, hash: String, mime: String, macID: String) {
        cards.save(bytes, hash: hash, macID: macID)
    }

    func cards(_ cards: [MacTabCard], epoch: String, macID: String) {
        self.cards.cards(cards.map { card in
            (tabID: card.tabID, info: MacCardInfo(
                title: card.title, kind: card.kind, faviconHash: card.faviconHash, thumbHash: card.thumbHash,
                screenHash: card.screenHash, screenColumns: card.screenColumns, screenRows: card.screenRows,
                capturedAtMs: Int64((card.capturedAt.timeIntervalSince1970 * 1000).rounded())))
        }, epoch: epoch, macID: macID)
    }

    func blobArrived(hash: String, tabIDs: [String], macID: String) {
        cards.blobArrived(hash: hash, tabIDs: tabIDs, macID: macID)
    }

    func remove(blobs: [String], macID: String) { cards.remove(blobs: blobs, macID: macID) }
}
#endif
