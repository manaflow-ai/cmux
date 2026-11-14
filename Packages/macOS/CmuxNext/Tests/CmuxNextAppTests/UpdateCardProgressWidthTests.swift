import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextSidebar
@testable import CmuxNextUpdater
import Testing

/// Lawrence 2026-11-07, on the Downloading Update card at 92% and the Preparing Update card: "cancel
/// button is ugly not taking up full width here". The progress bar stopped short of the card's right
/// padding, where the round cancel sat, even on Preparing, which has no cancel. The bar and the detail
/// span the card's whole inner width in every stage; the cancel is a quiet "Cancel" on the title's
/// row, at the top right, never in the bar's row.
@MainActor @Suite(.serialized) struct UpdateCardProgressWidthTests {
    static let mb: UInt64 = 1_000_000

    private func card(for stage: UpdateCard) -> SidebarNoticeCardView {
        let notice = SidebarCardFeed.notice(stage.presentation(version: "1.0.0", build: "100"), asked: true)
        let card = SidebarNoticeCardView(motionPolicy: { MotionPolicy(speed: .fast, reduceMotion: true) })
        card.frame = NSRect(x: 0, y: 0, width: 240, height: SidebarNoticeCardView.height(for: notice, width: 240))
        card.configure(notice)
        card.layoutSubtreeIfNeeded()
        return card
    }

    /// The loading stages with a bar: Downloading (with its cancel) and Preparing (none).
    private func stage(_ name: String) -> UpdateCard {
        name == "preparing" ? .downloading(.preparing(0.5)) : .downloading(.downloading(received: 230 * Self.mb, expected: 250 * Self.mb))
    }

    @Test(arguments: ["downloading", "preparing"])
    func theBarSpansTheCardsInnerWidth(_ name: String) {
        let card = card(for: stage(name))
        let pad = Metrics.space3
        #expect(!card.track.isHidden)
        #expect(abs(card.track.frame.minX - pad) <= 0.5, "the bar does not start at the padding: \(card.track.frame)")
        #expect(abs(card.track.frame.maxX - (card.bounds.width - pad)) <= 0.5,
                "the bar stops short of the right padding: \(card.track.frame) in \(card.bounds)")
    }

    @Test func theCancelIsAQuietTextButtonOnTheTitlesRow() {
        let card = card(for: .downloading(.downloading(received: 230 * Self.mb, expected: 250 * Self.mb)))
        let cancel = card.trailingButton
        #expect(!cancel.isHidden)
        #expect(cancel.title == UpdaterStrings.cancel)
        // On the title's row, at the top right, inside the padding corner.
        #expect(abs(cancel.frame.midY - card.titleLabel.frame.minY - card.titleLabel.frame.height / 2) <= 3,
                "the cancel is not on the title's row: \(cancel.frame) vs \(card.titleLabel.frame)")
        #expect(cancel.frame.maxX <= card.bounds.width - Metrics.space1)
        #expect(card.titleLabel.frame.maxX <= cancel.frame.minX, "the title runs under the cancel")
        // Above the bar, never beside it.
        #expect(cancel.frame.maxY <= card.track.frame.minY)
        var sent: [String] = []
        card.onAction = { sent.append($1) }
        cancel.onPress?()
        #expect(sent == [UpdateCardAction.cancelDownload.rawValue])
    }
}
