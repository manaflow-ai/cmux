import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
@testable import CmuxNextUpdater
import CmuxNextTestSupport
import CmuxUpdater
import Foundation
import Testing

/// A refused Go Back on the failed-check card shows why on the card (#49442: it reached only the
/// update log, and the card looked as if nothing happened). Leo, 2026-11-27: "as long as the merges
/// are good... i think we gotta start checkin a bit more now?"
@MainActor @Suite(.serialized, .closesItsWindows) struct HealthGoBackRefusalTests {
    static let failure = UpdateHealthFailure(previousBuild: "99", previousCommit: nil, build: "100", commit: nil,
                                             checks: [.init(name: "chat", ok: false, reason: "chat.handshake", detail: "")],
                                             canGoBack: true)

    static func updater() -> UpdaterService {
        let identity = UpdateBuildIdentity(bundleIdentifier: "com.cmuxterm.app.debug.health-go-back-refusal", shortVersion: "1.0.0",
                                           build: "100", minimumSystemVersion: nil,
                                           infoFeedURL: "https://files-next.cmux.com/nightly-next/appcast-arm64.xml", hasPublicKey: false)
        let defaults = UserDefaults(testSuiteName: "HealthGoBackRefusalTests.\(UUID().uuidString)")!
        let updater = UpdaterService(identity: identity, policy: ManagedUpdatePolicy { false }, defaults: defaults,
                                     enableSparkle: false, recordsUpdates: false, pausesAutomaticUpdates: true)
        updater.announcementsFetch = false
        return updater
    }

    @Test func aRefusedGoBackShowsItsReasonOnTheCard() async throws {
        let updater = Self.updater()
        updater.healthFailure = Self.failure
        let before = try #require(updater.card).presentation(version: "1.0.0", build: "100").detail
        // Another switch is running: the one drop-back path refuses with `busy`, and touches nothing.
        updater.switchRunning = true
        await updater.goBackAfterHealthFailure()
        let card = try #require(updater.card)
        #expect(card == .healthFailed(previousBuild: "99", reason: Self.failure.summary, refusal: UpdaterStrings.rollbackBusy))
        let detail = try #require(card.presentation(version: "1.0.0", build: "100").detail)
        #expect(detail.contains(UpdaterStrings.rollbackBusy))
        #expect(detail != before)
        #expect(card.presentation(version: "1.0.0", build: "100").actions == [.goBack], "Go Back stays to try again")
    }

    @Test func theCardBeforeAnyRefusalIsUnchanged() {
        let card = UpdateCard.healthFailed(previousBuild: "99", reason: "chat: chat.handshake")
        #expect(card.presentation(version: "1.0.0", build: "100").detail == UpdaterStrings.healthFailedDetail("chat: chat.handshake", "99"))
    }

    /// Stills for the PR: the card after a refused Go Back, before this change (no reason) and after
    /// it, dark and light, under `health-go-back-refusal-gallery/` (`cmux-ci run --artifact`).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let reason = Self.failure.summary
        let cards: [(String, UpdateCard)] = [
            ("before-refused", .healthFailed(previousBuild: "nightly 99", reason: reason)),
            ("after-refused", .healthFailed(previousBuild: "nightly 99", reason: reason,
                                            refusal: UpdaterStrings.rollbackStoreTooNew("nightly 99", "chat"))),
        ]
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "health-go-back-refusal-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for dark in [true, false] {
            for (name, card) in cards {
                let notice = SidebarCardFeed.notice(card.presentation(version: "1.0.0", build: "100"), asked: true)
                let image = try AAUpdateDownloadCardGalleryTests.notice(notice, dark: dark)
                try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(name)-\(dark ? "dark" : "light").png"))
            }
        }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "health-go-back-refusal-gallery.tar", "health-go-back-refusal-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
