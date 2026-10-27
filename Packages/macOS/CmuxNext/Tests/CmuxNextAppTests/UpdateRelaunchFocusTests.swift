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

    /// The reopen itself: an automatic install in a background app quits and reopens behind
    /// (`open -g`, so LaunchServices never activates it) and still writes the record as the
    /// safety net; a click, or the user being in the app, lets Sparkle relaunch and activate.
    @Test func anAutomaticInstallInABackgroundAppReopensBehindWithoutSparklesRelaunch() {
        let defaults = Self.defaults()
        let updater = Self.updater(defaults: defaults, front: Self.nightly)
        updater.keptRunningBuild = .kept
        updater.automaticInstallInFlight = true
        var willQuit: (@MainActor () -> Bool)?
        updater.relaunchBehind = { quit, _, _ in willQuit = quit }
        #expect(updater.updaterQuitsForAutomaticInstall(build: "200"))
        #expect(updater.installingBuild == "200")
        #expect(defaults.data(forKey: UpdateRelaunchFocus.key) == nil, "nothing is recorded before the helper runs")
        #expect(willQuit?() == true)
        #expect(UpdateRelaunchFocus.consume(defaults: defaults, build: "200", now: Self.start.addingTimeInterval(2))?.frontmostPID == 7045)
    }

    /// The user came into the app while the helper looked up the installer: no quit, no record;
    /// Sparkle relaunches it (activating).
    @Test func theUserComingInDuringTheLookupLetsSparkleRelaunch() {
        let defaults = Self.defaults()
        var front = Self.nightly
        let updater = Self.updater(defaults: defaults, front: front)
        updater.frontmost = { front }
        updater.keptRunningBuild = .kept
        updater.automaticInstallInFlight = true
        var willQuit: (@MainActor () -> Bool)?
        updater.relaunchBehind = { quit, _, _ in willQuit = quit }
        #expect(updater.updaterQuitsForAutomaticInstall(build: "200"))
        front = UpdateFrontmostApp(isThisApp: true, pid: 1, bundleID: "self")
        #expect(willQuit?() == false)
        #expect(defaults.data(forKey: UpdateRelaunchFocus.key) == nil)
    }

    /// The helper could not start, or the user refused the quit: the record goes and the next launch
    /// (one the user starts) is not held behind.
    @Test func aDeclinedQuitClearsTheRecord() {
        let defaults = Self.defaults()
        let updater = Self.updater(defaults: defaults, front: Self.nightly)
        updater.keptRunningBuild = .kept
        updater.automaticInstallInFlight = true
        var hooks: (willQuit: @MainActor () -> Bool, declined: @MainActor () -> Void)?
        updater.relaunchBehind = { quit, declined, _ in hooks = (quit, declined) }
        #expect(updater.updaterQuitsForAutomaticInstall(build: "200"))
        _ = hooks?.willQuit()
        #expect(defaults.data(forKey: UpdateRelaunchFocus.key) != nil)
        hooks?.declined()
        #expect(defaults.data(forKey: UpdateRelaunchFocus.key) == nil)
        #expect(!updater.automaticInstallInFlight)
    }

    @Test func aClickOrTheUserInTheAppLetsSparkleRelaunch() {
        for (automatic, front) in [(false, Self.nightly), (true, UpdateFrontmostApp(isThisApp: true, pid: 1, bundleID: "self"))] {
            let updater = Self.updater(defaults: Self.defaults(), front: front)
            updater.keptRunningBuild = .kept
            updater.automaticInstallInFlight = automatic
            var reopened = 0
            updater.relaunchBehind = { _, _, _ in reopened += 1 }
            #expect(!updater.updaterQuitsForAutomaticInstall(build: "200"))
            #expect(reopened == 0)
        }
    }

    @Test func helperLooksUpTheInstallerThenWaitsForTheAppThenOpensInTheBackground() {
        let app = URL(fileURLWithPath: "/Applications/cmux NEXT.app")
        let label = UpdateRelaunchBehind.installerJobLabel(bundleIdentifier: "com.cmuxterm.app.next")
        #expect(label == "com.cmuxterm.app.next-sparkle-updater")
        let arguments = UpdateRelaunchBehind.arguments(app: app, installerJob: label)
        #expect(arguments == ["/bin/sh", "-c", UpdateRelaunchBehind.script, app.path, label, UpdateRelaunchFocus.reopenArgument])
        #expect(UpdateRelaunchBehind.script.contains(#"exec /usr/bin/open -g "$0" --args "$2""#))
        #expect(UpdateRelaunchBehind.environment == ["PATH=/usr/bin:/bin:/usr/sbin:/sbin"], "open passes its environment to the new build")
    }

    /// The helper itself, with stand-ins. With no installer job it answers no pid (the app then
    /// stays); a refused quit ends it opening nothing; the app's end (EOF) with no installer to wait
    /// on ends it before `open` (exit 1).
    @Test func helperAnswersTheLookupAndStopsOnARefusedQuit() throws {
        let missing = "/nonexistent/cmux \(UUID().uuidString).app"
        let arguments = UpdateRelaunchBehind.arguments(app: URL(fileURLWithPath: missing), installerJob: "com.cmuxterm.test.no-such-job")
        for refused in [true, false] {
            let helper = try #require(UpdateRelaunchBehind.spawn(arguments))
            #expect(UpdateRelaunchBehind.readInstaller(helper.stdout, timeoutMilliseconds: 10_000) == nil, "no such job: no pid")
            close(helper.stdout)
            if refused {
                UpdateRelaunchBehind.refuse(helper.writeEnd)
            } else {
                close(helper.writeEnd)
            }
            var status: Int32 = 0
            var reaped: pid_t = 0
            repeat { reaped = waitpid(helper.pid, &status, 0) } while reaped == -1 && errno == EINTR
            #expect(reaped == helper.pid)
            let code = (status >> 8) & 0xff
            #expect(code == (refused ? 0 : 1), "refused=\(refused) exit=\(code)")
        }
    }

    @Test func readInstallerTakesOnePidLine() throws {
        for (written, expected) in [("4242\n", Int32(4242)), ("\n", nil), ("x\n", nil)] as [(String, Int32?)] {
            var ends: [Int32] = [-1, -1]
            try #require(pipe(&ends) == 0)
            let bytes = Array(written.utf8)
            _ = bytes.withUnsafeBufferPointer { write(ends[1], $0.baseAddress, $0.count) }
            close(ends[1])
            #expect(UpdateRelaunchBehind.readInstaller(ends[0], timeoutMilliseconds: 1_000) == expected)
            close(ends[0])
        }
    }

    /// A background reopen stays behind whatever build starts (a failed install puts the previous
    /// one back) and however long the quit took; an ordinary launch ignores a stale record.
    @Test func aBackgroundReopenStaysBehindForAnyBuildAndAge() {
        let defaults = Self.defaults()
        let record = UpdateRelaunchFocus(targetBuild: "200", recordedAt: Self.start, frontmostPID: 7045, frontmostBundleID: "x")
        UpdateRelaunchFocus.write(record, defaults: defaults)
        #expect(UpdateRelaunchFocus.consume(defaults: defaults, build: "100", now: Self.start.addingTimeInterval(600), reopenedBehind: true) == record)
        let none = UpdateRelaunchFocus.consume(defaults: defaults, build: "100", now: Self.start, reopenedBehind: true)
        #expect(none != nil && none?.frontmostPID == nil, "no record: still behind, with no app to hand back to")
        UpdateRelaunchFocus.write(record, defaults: defaults)
        #expect(UpdateRelaunchFocus.consume(defaults: defaults, build: "100", now: Self.start.addingTimeInterval(600)) == nil)
    }
}
