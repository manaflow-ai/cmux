import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextSidebar
@testable import CmuxNextUpdater
import CmuxUpdater
import Foundation
import Testing

/// Leo 2026-10-31: "AND WHY CAN'T I CANCEL THE DOWNLOAD OPTIONALLY AND WHY IS THE SYMBOL SO
/// FUCKING SMALL THIS IS SHIT ASS SPACING WHY NOT JUST LEFT ALIGN THE TEXT PUT A BIGGER SYMBOL ON
/// THE RIGHT" / "ALSO CENTER THE FUCKING BUTTON ON THE RIGHT VERTICALLY". The downloading card's
/// text starts at the card's padding, a bigger cancel sits on the right, vertically centred, and
/// the cancel stops the download and puts the found update back on the card.
@MainActor @Suite(.serialized) struct UpdateDownloadCancelTests {
    static let mb: UInt64 = 1_000_000
    static let downloading = UpdateIndicatorPhase.downloading(.downloading(received: 62 * mb, expected: 250 * mb))

    @Test func theDownloadingCardHasACancelOnTheRightAndNoLeadingGlyph() throws {
        let shown = UpdateCard.downloading(.downloading(received: 62 * Self.mb, expected: 250 * Self.mb))
            .presentation(version: "1.0.0", build: "100")
        #expect(shown.trailing == .cancelDownload)
        let notice = SidebarCardFeed.notice(shown, asked: true)
        #expect(notice.symbol == nil, "the status card still draws a small glyph before its text")
        #expect(notice.trailing?.id == UpdateCardAction.cancelDownload.rawValue)
        // Checking and unpacking have nothing to cancel.
        #expect(UpdateCard.checking.presentation(version: "1.0.0", build: "100").trailing == nil)
        #expect(UpdateCard.downloading(.preparing(0.5)).presentation(version: "1.0.0", build: "100").trailing == nil)
    }

    @Test func theTextIsLeftAlignedAndTheCancelIsBigAndVerticallyCentred() throws {
        let shown = UpdateCard.downloading(.downloading(received: 62 * Self.mb, expected: 250 * Self.mb))
            .presentation(version: "1.0.0", build: "100")
        let notice = SidebarCardFeed.notice(shown, asked: true)
        let card = SidebarNoticeCardView(motionPolicy: { MotionPolicy(speed: .fast, reduceMotion: true) })
        card.frame = NSRect(x: 0, y: 0, width: 240, height: SidebarNoticeCardView.height(for: notice))
        card.configure(notice)
        card.layoutSubtreeIfNeeded()
        let pad = Metrics.space3
        #expect(card.titleLabel.frame.minX == pad, "the title is indented: \(card.titleLabel.frame)")
        let button = card.trailingButton
        #expect(!button.isHidden)
        #expect(abs(button.frame.midY - card.bounds.midY) <= 0.5, "the cancel is not vertically centred: \(button.frame) in \(card.bounds)")
        #expect(abs(button.frame.maxX - (card.bounds.width - pad)) <= 0.5, "the cancel is off the right padding: \(button.frame)")
        #expect(button.frame.width >= 24, "the cancel is still tiny: \(button.frame)")
        #expect(card.titleLabel.frame.maxX <= button.frame.minX, "the title runs under the cancel")
        var sent: [(String, String)] = []
        card.onAction = { sent.append(($0, $1)) }
        button.onPress?()
        #expect(sent.map(\.1) == [UpdateCardAction.cancelDownload.rawValue])
    }

    @Test func cancelStopsTheDownloadAndReturnsToTheFoundUpdate() {
        let updater = UpdateLoadingIndicatorTests.updater()
        var cancels = 0
        updater.cancelDownloadNow = {
            cancels += 1
            // Sparkle's cancellation deletes the partial file and goes idle.
            updater.debugIndicatorPhase = .hidden
            return true
        }
        var downloads = 0
        updater.acceptAvailable = { downloads += 1 }
        updater.send(.checkRequested)
        for phase: UpdateIndicatorPhase in [.checking, .downloading(.starting), Self.downloading] {
            updater.debugIndicatorPhase = phase
            updater.syncFlowPhase()
        }
        #expect(updater.card == .downloading(.downloading(received: 62 * Self.mb, expected: 250 * Self.mb)))

        updater.performCardAction(.cancelDownload)
        #expect(cancels == 1, "the cancel did not stop the download")
        #expect(updater.card == .available(version: nil), "the card did not go back to the found update: \(String(describing: updater.card))")
        let notice = SidebarCardFeed.noticeCard(updater, registry: nil)
        #expect(notice?.actions.map(\.id).contains(UpdateCardAction.update.rawValue) == true, "the found update offers no Update")
        #expect(notice?.trailing == nil)

        // A second cancel with nothing running does nothing.
        updater.performCardAction(.cancelDownload)
        #expect(cancels == 1)

        // Update checks again, and the update the check finds downloads.
        updater.performCardAction(.update)
        #expect(updater.cancelledDownload == nil)
        for phase: UpdateIndicatorPhase in [.checking, .available(version: "1.0.1")] {
            updater.debugIndicatorPhase = phase
            updater.syncFlowPhase()
        }
        #expect(downloads == 1, "Update after a cancel did not download the found update")
    }

    @Test func anUpdateClickWhoseCheckEndsEmptyDoesNotDownloadALaterUpdate() {
        let updater = UpdateLoadingIndicatorTests.updater()
        updater.cancelDownloadNow = {
            updater.debugIndicatorPhase = .hidden
            return true
        }
        var downloads = 0
        updater.acceptAvailable = { downloads += 1 }
        updater.send(.checkRequested)
        updater.debugIndicatorPhase = Self.downloading
        updater.syncFlowPhase()
        updater.cancelDownloadClicked()
        updater.performCardAction(.update)
        // The check that Update started ends with nothing; later a scheduled check finds an update.
        for phase: UpdateIndicatorPhase in [.checking, .hidden, .checking, .available(version: "1.0.2")] {
            updater.debugIndicatorPhase = phase
            updater.syncFlowPhase()
        }
        #expect(downloads == 0, "a scheduled check's update downloaded on an old click")
    }

    @Test func aNewCheckEndsTheCancelledCard() {
        let updater = UpdateLoadingIndicatorTests.updater()
        updater.cancelDownloadNow = {
            updater.debugIndicatorPhase = .hidden
            return true
        }
        updater.send(.checkRequested)
        updater.debugIndicatorPhase = Self.downloading
        updater.syncFlowPhase()
        updater.cancelDownloadClicked()
        #expect(updater.cancelledDownload != nil)
        updater.debugIndicatorPhase = .checking
        updater.syncFlowPhase()
        #expect(updater.cancelledDownload == nil)
    }
}
