import Foundation
@testable import CmuxNextUpdater
import Testing

/// An update never pulls the user into the app (Leo 2026-10-26: "stop opening up my next dev ...
/// I'm not looking at it right now. So stop automatically putting me in there."). An install
/// nobody clicked, in an app that is not frontmost, relaunches behind the user's app; a click, or
/// the user being in the app, keeps the activation; a stale record does nothing.
@MainActor @Suite(.serialized) struct UpdateRelaunchFocusTests {
    private static let start = Date(timeIntervalSince1970: 1_800_000_000)

    private static func defaults() -> UserDefaults {
        UserDefaults(suiteName: "UpdateRelaunchFocusTests.\(UUID().uuidString)")!
    }

    private static func updater(defaults: UserDefaults, front: UpdateFrontmostApp) -> UpdaterService {
        let identity = UpdateBuildIdentity(bundleIdentifier: "com.cmuxterm.app.debug.relaunch-focus", shortVersion: "1.0.0",
                                           build: "100", minimumSystemVersion: nil,
                                           infoFeedURL: "https://files-next.cmux.com/nightly-next/appcast-arm64.xml", hasPublicKey: false)
        let updater = UpdaterService(identity: identity, policy: ManagedUpdatePolicy { false }, defaults: defaults,
                                     enableSparkle: false, recordsUpdates: false, now: { Self.start })
        updater.frontmost = { front }
        return updater
    }

    private static let nightly = UpdateFrontmostApp(isThisApp: false, pid: 7045, bundleID: "com.cmuxterm.app.nightly.next")

    @Test func onlyAnAutomaticInstallInABackgroundAppStaysBehind() {
        #expect(UpdateRelaunchFocus.staysBehind(automatic: true, appIsFrontmost: false))
        #expect(!UpdateRelaunchFocus.staysBehind(automatic: true, appIsFrontmost: true))
        #expect(!UpdateRelaunchFocus.staysBehind(automatic: false, appIsFrontmost: false))
        #expect(!UpdateRelaunchFocus.staysBehind(automatic: false, appIsFrontmost: true))
    }

    @Test func aRecordAppliesOnlyToItsBuildWhileFresh() {
        let record = UpdateRelaunchFocus(targetBuild: "200", recordedAt: Self.start, frontmostPID: 1, frontmostBundleID: nil)
        #expect(record.applies(toBuild: "200", now: Self.start.addingTimeInterval(3)))
        #expect(!record.applies(toBuild: "100", now: Self.start.addingTimeInterval(3)), "the install did not happen")
        #expect(!record.applies(toBuild: "200", now: Self.start.addingTimeInterval(UpdateRelaunchFocus.maxAge + 1)), "stale")
        #expect(!record.applies(toBuild: "200", now: Self.start.addingTimeInterval(-3600)), "written in the future")
        let unnamed = UpdateRelaunchFocus(targetBuild: nil, recordedAt: Self.start, frontmostPID: nil, frontmostBundleID: nil)
        #expect(unnamed.applies(toBuild: "anything", now: Self.start.addingTimeInterval(10)))
    }

    @Test func consumeReturnsTheRecordOnceAndClearsAStaleOne() {
        let defaults = Self.defaults()
        let record = UpdateRelaunchFocus(targetBuild: "200", recordedAt: Self.start, frontmostPID: 7045, frontmostBundleID: "x")
        UpdateRelaunchFocus.write(record, defaults: defaults)
        #expect(UpdateRelaunchFocus.consume(defaults: defaults, build: "200", now: Self.start.addingTimeInterval(5)) == record)
        #expect(UpdateRelaunchFocus.consume(defaults: defaults, build: "200", now: Self.start.addingTimeInterval(5)) == nil, "used once")

        UpdateRelaunchFocus.write(record, defaults: defaults)
        #expect(UpdateRelaunchFocus.consume(defaults: defaults, build: "200", now: Self.start.addingTimeInterval(3600)) == nil)
        #expect(defaults.data(forKey: UpdateRelaunchFocus.key) == nil, "a stale record is cleared")

        defaults.set(Data("not json".utf8), forKey: UpdateRelaunchFocus.key)
        #expect(UpdateRelaunchFocus.consume(defaults: defaults, build: "200") == nil)
        #expect(defaults.data(forKey: UpdateRelaunchFocus.key) == nil)
    }

    @Test func anAutomaticInstallWhileTheUserIsInAnotherAppRelaunchesBehindIt() {
        let defaults = Self.defaults()
        let updater = Self.updater(defaults: defaults, front: Self.nightly)
        updater.automaticInstallInFlight = true
        updater.installingBuild = "200"
        updater.updaterWillRelaunchApplication()
        let record = UpdateRelaunchFocus.consume(defaults: defaults, build: "200", now: Self.start.addingTimeInterval(2))
        #expect(record == UpdateRelaunchFocus(targetBuild: "200", recordedAt: Self.start, frontmostPID: 7045,
                                              frontmostBundleID: "com.cmuxterm.app.nightly.next"))
    }

    @Test func anAutomaticInstallWhileTheUserIsInTheAppActivatesAsBefore() {
        let defaults = Self.defaults()
        let updater = Self.updater(defaults: defaults, front: UpdateFrontmostApp(isThisApp: true, pid: 1, bundleID: "self"))
        updater.automaticInstallInFlight = true
        updater.installingBuild = "200"
        updater.recordRelaunchFocus()
        #expect(defaults.data(forKey: UpdateRelaunchFocus.key) == nil)
    }

    @Test func aClickedInstallActivatesAndClearsAnOlderRecord() {
        let defaults = Self.defaults()
        UpdateRelaunchFocus.write(UpdateRelaunchFocus(targetBuild: "200", recordedAt: Self.start, frontmostPID: 1, frontmostBundleID: nil),
                                  defaults: defaults)
        let updater = Self.updater(defaults: defaults, front: Self.nightly)
        updater.automaticInstallInFlight = false
        updater.installingBuild = "200"
        updater.recordRelaunchFocus()
        #expect(defaults.data(forKey: UpdateRelaunchFocus.key) == nil, "a click relaunches to the front")
    }

    @Test func anAutomaticInstallThatStartedWhileTheUserWasInTheAppActivatesAsBefore() {
        let defaults = Self.defaults()
        let updater = Self.updater(defaults: defaults, front: Self.nightly)
        updater.automaticInstallInFlight = true
        updater.automaticInstallFrontmost = UpdateFrontmostApp(isThisApp: true, pid: 1, bundleID: "self")
        updater.installingBuild = "200"
        updater.recordRelaunchFocus()
        #expect(defaults.data(forKey: UpdateRelaunchFocus.key) == nil, "frontmost when the install started")
    }
}
