import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextSidebar
@testable import CmuxNextUpdater
import CmuxUpdater
import Foundation
import Testing

/// Check for Updates, then Attempt Update, "needs better loading indicator"
/// (Lawrence 2026-10-20). One card follows the whole flow the person asked
/// for: checking, starting the download, the bytes as they arrive, the
/// archive being verified and unpacked, then the install and relaunch. Each
/// stage says what it is, a measured stage shows its fraction and bytes, an
/// unmeasured one sweeps the bar, and the card never changes height or swaps
/// for another card halfway.
@MainActor @Suite(.serialized) struct UpdateLoadingIndicatorTests {
    static let moving = MotionPolicy(speed: .fast, reduceMotion: false)
    static let reduced = MotionPolicy(speed: .fast, reduceMotion: true)
    static let mb: UInt64 = 1_000_000

    /// The phases Sparkle reports through an Attempt Update that installs.
    static let attemptPhases: [UpdateIndicatorPhase] = [
        .checking,
        .downloading(.starting),
        .downloading(.downloading(received: 0, expected: 48 * mb)),
        .downloading(.downloading(received: 12 * mb, expected: 48 * mb)),
        .downloading(.downloading(received: 48 * mb, expected: 48 * mb)),
        .downloading(.preparing(nil)),
        .downloading(.preparing(0.6)),
        .installing,
    ]

    static func presentation(_ card: UpdateCard) -> UpdateCardPresentation {
        card.presentation(version: "1.0.0", build: "100")
    }

    @Test func attemptUpdateShowsOneLoadingCardFromCheckToRelaunch() throws {
        var flow = UpdateFlow()
        _ = flow.handle(.checkRequested, preferences: .defaults)
        var titles: [String] = []
        for phase in Self.attemptPhases {
            _ = flow.handle(.sparkle(phase), preferences: .defaults)
            let card = try #require(flow.card(downloadsAutomatically: true), "the loading card left at \(phase)")
            let shown = Self.presentation(card)
            #expect(shown.showsProgress, "\(phase) shows no progress")
            #expect(!shown.dismissible, "\(phase) can be dismissed while it works")
            if titles.last != shown.title { titles.append(shown.title) }
        }
        #expect(titles == [UpdaterStrings.checking, UpdaterStrings.startingDownload, UpdaterStrings.downloading,
                           UpdaterStrings.preparing, UpdaterStrings.installingUpdate],
                "the stages are not named in order: \(titles)")
        #expect(flow.card(downloadsAutomatically: true) == .installing)
    }

    @Test func theDownloadShowsItsBytesAndPercent() throws {
        let shown = Self.presentation(.downloading(.downloading(received: 12 * Self.mb, expected: 48 * Self.mb)))
        #expect(shown.progress == 0.25)
        let detail = try #require(shown.detail)
        #expect(detail.contains("25%"), "the download says no percent: \(detail)")
        #expect(detail.contains("12") && detail.contains("48"), "the download says no byte counts: \(detail)")
        // The server did not say the size: the bytes still count up, the bar sweeps.
        let unsized = Self.presentation(.downloading(.downloading(received: 3 * Self.mb, expected: nil)))
        #expect(unsized.progress == nil)
        #expect(unsized.detail?.contains("3") == true, "an unsized download says nothing: \(String(describing: unsized.detail))")
    }

    @Test func unpackingIsNotCalledADownload() {
        let state = UpdateState.extracting(.init(progress: 0.4))
        let phase = UpdateIndicatorPhase(state, version: nil)
        #expect(phase == .downloading(.preparing(0.4)))
        #expect(Self.presentation(.downloading(.preparing(0.4))).title == UpdaterStrings.preparing)
        let bytes = UpdateIndicatorPhase(.downloading(.init(cancel: {}, expectedLength: 200, progress: 50)), version: nil)
        #expect(bytes == .downloading(.downloading(received: 50, expected: 200)))
    }

    @Test func theCardKeepsItsHeightThroughEveryStage() {
        var flow = UpdateFlow()
        _ = flow.handle(.checkRequested, preferences: .defaults)
        var heights: Set<CGFloat> = []
        for phase in Self.attemptPhases {
            _ = flow.handle(.sparkle(phase), preferences: .defaults)
            guard let card = flow.card(downloadsAutomatically: true) else { continue }
            heights.insert(SidebarNoticeCardView.height(for: SidebarCardFeed.notice(Self.presentation(card), asked: true)))
        }
        #expect(heights.count == 1, "the card jumps between heights while it loads: \(heights.sorted())")
    }

    @Test func unmeasuredWorkSweepsTheBarAndMeasuredWorkFillsIt() {
        let checking = SidebarCardFeed.notice(Self.presentation(.checking), asked: true)
        let card = SidebarNoticeCardView(motionPolicy: { Self.moving })
        card.frame = NSRect(x: 0, y: 0, width: 240, height: SidebarNoticeCardView.height(for: checking))
        card.configure(checking)
        card.layoutSubtreeIfNeeded()
        #expect(card.progressShown == .sweeping, "checking shows no moving bar: \(card.progressShown)")

        let half = SidebarCardFeed.notice(Self.presentation(.downloading(.downloading(received: 24 * Self.mb, expected: 48 * Self.mb))), asked: true)
        card.configure(half)
        card.layoutSubtreeIfNeeded()
        guard case .fraction(let fraction) = card.progressShown else {
            Issue.record("a measured download shows no bar: \(card.progressShown)")
            return
        }
        #expect(abs(fraction - 0.5) < 0.01)

        // Reduce Motion: no sweep; the spinner glyph alone moves.
        let still = SidebarNoticeCardView(motionPolicy: { Self.reduced })
        still.frame = card.frame
        still.configure(checking)
        still.layoutSubtreeIfNeeded()
        #expect(still.progressShown == .still)
    }

    @Test func aTickingByteCountDoesNotCrossfadeTheCard() {
        let a = SidebarCardFeed.notice(Self.presentation(.downloading(.downloading(received: 12 * Self.mb, expected: 48 * Self.mb))))
        let b = SidebarCardFeed.notice(Self.presentation(.downloading(.downloading(received: 13 * Self.mb, expected: 48 * Self.mb))))
        #expect(!SidebarNoticeCardView.changesMessage(from: a, to: b), "every byte count would crossfade the card")
        let preparing = SidebarCardFeed.notice(Self.presentation(.downloading(.preparing(nil))))
        #expect(SidebarNoticeCardView.changesMessage(from: b, to: preparing))
    }

    @Test func restartToUpdateKeepsTheStagedCardAndSaysItInstalls() {
        var flow = UpdateFlow()
        _ = flow.handle(.sparkle(.ready(version: "1.0.1")), preferences: .defaults)
        #expect(flow.handle(.installRequested, preferences: .defaults) == [.install])
        _ = flow.handle(.sparkle(.installing), preferences: .defaults)
        #expect(flow.card(downloadsAutomatically: true) == nil, "the click on the staged card swapped it for the notice card")
        #expect(flow.footerPill(preferences: .defaults) == .installing)
        let card = UpdateReadyCard(version: "1.0.1", isInstalling: true, automaticUpdates: true,
                                   notes: UpdateReadyNotes(version: "1.0.1", notes: nil, fullNotesURL: nil))
        #expect(card.title == UpdaterStrings.installingUpdate, "the installing card still reads \(card.title)")
    }

    @Test func anInstallFollowedOnTheNoticeCardIsNotAlsoTheStagedCard() {
        let identity = UpdateBuildIdentity(bundleIdentifier: "com.cmuxterm.app.debug.update-loading", shortVersion: "1.0.0",
                                           build: "100", minimumSystemVersion: nil,
                                           infoFeedURL: "https://files-next.cmux.com/nightly-next/appcast-arm64.xml", hasPublicKey: false)
        let defaults = UserDefaults(suiteName: "UpdateLoadingIndicatorTests.\(UUID().uuidString)")!
        let updater = UpdaterService(identity: identity, policy: ManagedUpdatePolicy { false }, defaults: defaults,
                                     enableSparkle: false, recordsUpdates: false)
        updater.announcementsFetch = false
        updater.send(.checkRequested)
        for phase in Self.attemptPhases {
            updater.debugIndicatorPhase = phase
            updater.syncFlowPhase()
            #expect(updater.card != nil, "the loading card left at \(phase)")
        }
        #expect(updater.card == .installing)
        #expect(updater.readyCard == nil, "two cards say the update installs")
        let notice = SidebarCardFeed.noticeCard(updater, registry: nil)
        #expect(notice?.title == UpdaterStrings.installingUpdate)
        #expect(notice?.progress == .indeterminate)
    }
}
