import CmuxUpdater
import Foundation
@preconcurrency import Sparkle
import Testing
@testable import CmuxNextUpdater

/// The rail's update circle over Sparkle's flow: nothing asks, a waiting
/// update is the circle, and a check that finds nothing is a short note.
@MainActor
@Suite struct UpdateIndicatorPhaseTests {
    private let item = SUAppcastItem(dictionary: [
        "title": "cmux 0.71.0",
        "pubDate": "Wed, 25 Mar 2026 12:00:00 +0000",
        "enclosure": ["url": "https://example.com/cmux.zip", "length": "1024",
                      "sparkle:version": "300", "sparkle:shortVersionString": "0.71.0"],
    ])!

    @Test func quietStatesHideTheCircle() {
        #expect(UpdateIndicatorPhase(.idle, version: nil) == .hidden)
        #expect(!UpdateIndicatorPhase.hidden.showsCircle)
    }

    @Test func downloadingFillsTheRingWhenTheSizeIsKnown() {
        let half = UpdateState.downloading(.init(cancel: {}, expectedLength: 200, progress: 100))
        #expect(UpdateIndicatorPhase(half, version: nil) == .downloading(progress: 0.5))
        let unknown = UpdateState.downloading(.init(cancel: {}, expectedLength: nil, progress: 100))
        #expect(UpdateIndicatorPhase(unknown, version: nil) == .downloading(progress: nil))
        #expect(UpdateIndicatorPhase(.startingDownload, version: nil) == .downloading(progress: nil))
        #expect(UpdateIndicatorPhase(.extracting(.init(progress: 0.3)), version: nil) == .downloading(progress: nil))
    }

    @Test func aStagedUpdateIsTheReadyCircleAndAnInstallIsThePill() {
        let staged = UpdateState.installing(.init(isAutoUpdate: true, retryTerminatingApplication: {}, dismiss: {}))
        let phase = UpdateIndicatorPhase(staged, version: "0.71.0")
        #expect(phase == .ready(version: "0.71.0"))
        #expect(phase.showsCircle)
        #expect(phase.pillText == nil)
        #expect(phase.toolTip == UpdaterStrings.available("0.71.0") + "\n" + UpdaterStrings.install)

        let installing = UpdateIndicatorPhase(.installing(.init(retryTerminatingApplication: {}, dismiss: {})), version: nil)
        #expect(installing == .installing)
        #expect(installing.pillText == UpdaterStrings.installing)
    }

    @Test func aPromptStillShowsAsTheReadyCircle() {
        let available = UpdateState.updateAvailable(.init(appcastItem: item, reply: { _ in }))
        #expect(UpdateIndicatorPhase(available, version: nil) == .ready(version: "0.71.0"))
    }

    @Test func checkResultsAreNotesNotSheets() {
        let upToDate = UpdateIndicatorPhase(.notFound(.init(acknowledgement: {})), version: nil)
        #expect(upToDate == .note(UpdaterStrings.upToDate, isError: false))
        #expect(!upToDate.showsCircle)
        #expect(upToDate.pillText == UpdaterStrings.upToDate)
        #expect(UpdateIndicatorPhase(probe: nil, error: "offline", probing: false) == .note(UpdaterStrings.checkFailed, isError: true))
        #expect(UpdateIndicatorPhase(probe: nil, error: nil, probing: true) == .checking)
        #expect(UpdateIndicatorPhase(probe: nil, error: nil, probing: false) == .hidden)
    }

    /// The ring spins while nothing measures progress, never for a known fraction.
    @Test func onlyUnmeasuredWorkSpins() {
        #expect(UpdateIndicatorPhase.checking.spins)
        #expect(UpdateIndicatorPhase.installing.spins)
        #expect(UpdateIndicatorPhase.downloading(progress: nil).spins)
        #expect(!UpdateIndicatorPhase.downloading(progress: 0.75).spins)
        #expect(!UpdateIndicatorPhase.ready(version: nil).spins)
    }
}
