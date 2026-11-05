import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextSidebar
@testable import CmuxNextUpdater
import Foundation
import Testing

/// Leo 2026-11-04, after his second click landed on Restart to Update when the download's card turned into
/// the staged update's: "i only clicked the "download" button and it allegedly "updated" but i didnt
/// restart the app/get a prompt to?"; 2026-11-05: "can we have, like, a better-looking update downloading
/// thing?". The bottom slot keeps a card's bottom edge (`SidebarBottomCardSlot.place(above:)`), so the
/// ready card's Restart button must not cover any point of the download card's cancel: a click meant for
/// Cancel lands on the card, never on Restart. Each card keeps its own height.
@MainActor @Suite(.serialized) struct UpdateRestartColumnTests {
    static let width: CGFloat = 224

    /// `frame` (in `view`, flipped) measured up from the card's bottom edge, as the slot places cards.
    static func fromBottom(_ frame: NSRect, in view: NSView) -> NSRect {
        NSRect(x: frame.minX, y: view.bounds.height - frame.maxY, width: frame.width, height: frame.height)
    }

    static func downloadCard() -> SidebarNoticeCardView {
        let notice = SidebarCardFeed.notice(UpdateCard.downloading(.downloading(received: 260_000_000, expected: 265_300_000))
            .presentation(version: "1.0.0", build: "100"), asked: true)
        let view = SidebarNoticeCardView(motionPolicy: { MotionPolicy(speed: .fast, reduceMotion: true) })
        view.frame = NSRect(x: 0, y: 0, width: width, height: SidebarNoticeCardView.height(for: notice))
        view.configure(notice)
        view.layoutSubtreeIfNeeded()
        return view
    }

    static func readyCard() -> SidebarUpdateCardView {
        let card = SidebarCardFeed.updateCard(UpdateReadyCard(version: "nightly 200", isInstalling: false, automaticUpdates: true,
                                                              notes: UpdateReadyNotes(version: "nightly 200", notes: nil, fullNotesURL: nil)))
        let view = SidebarUpdateCardView(frame: NSRect(x: 0, y: 0, width: width, height: SidebarUpdateCardView.height(for: card)))
        view.configure(card)
        view.layoutSubtreeIfNeeded()
        return view
    }

    @Test func restartNeverCoversTheCancelItReplaces() throws {
        let download = Self.downloadCard(), ready = Self.readyCard()
        #expect(!download.trailingButton.isHidden, "the download card shows no cancel")
        let cancel = Self.fromBottom(download.trailingButton.frame, in: download)
        let restart = Self.fromBottom(ready.button.frame, in: ready)
        #expect(!restart.intersects(cancel), "Restart \(restart) sits under the cancel \(cancel) it replaces")
        // Restart still reads whole, on the card's bottom row.
        #expect(restart.width >= ceil((ready.button.title as NSString).size(withAttributes: [.font: SidebarUpdateButton.font]).width))
    }
}
