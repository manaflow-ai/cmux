import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
@testable import CmuxNextUpdater
import Testing

/// Restart to Update (incident 2026-10-20, #22919): the windows left the screen at the click, and a
/// click whose install never reached the installer kept them invisible for 7 s. They are now frozen,
/// never hidden (Leo 2026-11-22: "the hide then animation then going to the updated to nightly is
/// just bad."), when Sparkle commits to the relaunch. Review of #22919 at c0756ab, finding 2: that
/// hook also runs for an install nobody clicked (Sparkle's automatic driver, the relaunch behind the
/// person's app), whose failures bring nothing back, so only a relaunch the person asked for freezes
/// the windows, and a relaunch behind that does not quit unfreezes them.
@MainActor @Suite(.serialized, .closesItsWindows) struct UpdateRelaunchHandoffTests {
    private static func updater() -> UpdaterService {
        let identity = UpdateBuildIdentity(bundleIdentifier: "com.cmuxterm.app.debug.relaunch-handoff", shortVersion: "1.0.0",
                                           build: "100", minimumSystemVersion: nil,
                                           infoFeedURL: "https://files-next.cmux.com/nightly-next/appcast-arm64.xml", hasPublicKey: false)
        let defaults = UserDefaults(testSuiteName: "UpdateRelaunchHandoffTests.\(UUID().uuidString)")!
        let updater = UpdaterService(identity: identity, policy: ManagedUpdatePolicy { false }, defaults: defaults,
                                     enableSparkle: false, recordsUpdates: false, now: { Date(timeIntervalSince1970: 1_800_000_000) })
        updater.frontmost = { UpdateFrontmostApp(isThisApp: true, pid: 1, bundleID: "com.cmuxterm.app.debug.relaunch-handoff") }
        return updater
    }

    @Test func aClickedInstallFreezesTheWindowsWhenSparkleCommitsToTheRelaunch() {
        let updater = Self.updater()
        var relaunches = 0, freezes = 0
        updater.willRelaunch = { relaunches += 1 }
        updater.freezesForRelaunch = { freezes += 1 }
        updater.automaticInstallInFlight = false
        updater.updaterWillRelaunchApplication()
        #expect(relaunches == 1)
        #expect(freezes == 1, "the relaunch the person clicked for left the windows taking clicks")
    }

    @Test func anInstallNobodyClickedNeverFreezesTheWindows() {
        let updater = Self.updater()
        var relaunches = 0, freezes = 0
        updater.willRelaunch = { relaunches += 1 }
        updater.freezesForRelaunch = { freezes += 1 }
        updater.automaticInstallInFlight = true
        updater.updaterWillRelaunchApplication()
        #expect(relaunches == 1, "the relaunch still keeps every session")
        #expect(freezes == 0, "an automatic install froze the windows, and its failure would never unfreeze them")
    }

    /// Leo 2026-11-22: "the hide then animation then going to the updated to nightly is just bad."
    /// The relaunch's windows stay on screen exactly as they are: frozen, never transparent.
    @Test func theRelaunchKeepsTheWindowsOnScreenAndOnlyTakesTheirClicks() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.close() }
        let handoff = UpdateWindowHandoff(unsaved: QuitUnsavedRegistry())
        #expect(handoff.freeze())
        #expect(window.isVisible && window.alphaValue == 1, "the relaunch hid or faded a window")
        #expect(window.ignoresMouseEvents, "a frozen window still took clicks while the old app exits")
        handoff.restore()
        #expect(window.alphaValue == 1 && !window.ignoresMouseEvents, "a failed install did not give the window its clicks back")
    }

    /// Restart to Update becoming Installing… swaps in place: no crossfade leads into the relaunch.
    /// A failed install's way back to Restart to Update still crossfades.
    @Test func installingSwapsInPlaceWithNoCrossfade() {
        let view = SidebarUpdateCardView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
        view.motionPolicy = { MotionPolicy(speed: .fast, reduceMotion: false) }
        view.configure(AARestartToUpdateGalleryTests.card(installing: false))
        view.layer?.removeAllAnimations()
        view.configure(AARestartToUpdateGalleryTests.card(installing: true))
        #expect(view.card?.isEnabled == false)
        #expect(view.layer?.animation(forKey: SidebarCardTransition.crossfadeKey) == nil, "Installing… crossfaded into the relaunch")
        view.configure(AARestartToUpdateGalleryTests.card(installing: false))
        #expect(view.layer?.animation(forKey: SidebarCardTransition.crossfadeKey) != nil, "a failed install's card popped back")
    }

    /// The update status notice's Installing state (Attempt Update, a check that went on to install)
    /// comes in with no entrance; any other notice still plays it.
    @Test func theInstallingNoticeComesInWithNoEntrance() {
        for atOnce in [true, false] {
            let view = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 80))
            view.wantsLayer = true
            view.isHidden = true
            let presence = SidebarCardPresence(view, policy: { MotionPolicy(speed: .fast, reduceMotion: false) })
            presence.showsNextAtOnce = atOnce
            presence.setShown(true)
            presence.didLayout()
            #expect(!view.isHidden)
            #expect((view.layer?.animation(forKey: SidebarCardTransition.opacityKey) == nil) == atOnce,
                    atOnce ? "Installing… faded in ahead of the relaunch" : "a notice lost its entrance")
        }
    }

    @Test func aRelaunchBehindThatDoesNotQuitUnfreezesTheWindows() {
        let updater = Self.updater()
        var abandoned = 0
        updater.installAbandoned = { abandoned += 1 }
        updater.automaticInstallInFlight = true
        updater.quitForInstallDeclined()
        #expect(abandoned == 1, "the app kept running after its relaunch-behind quit was declined, with no restore")
        #expect(!updater.automaticInstallInFlight)
    }

    /// Review of #22919 at 0088e20, finding 3: an automatic install that fails after it began to
    /// install unfreezes any window the relaunch froze.
    @Test func anAutomaticInstallThatFailsUnfreezesTheWindows() {
        let updater = Self.updater()
        updater.announcementsFetch = false
        var abandoned = 0
        updater.installAbandoned = { abandoned += 1 }
        updater.send(.checkRequested)
        for phase: UpdateIndicatorPhase in [.checking, .downloading(.starting), .downloading(.preparing(nil)), .installing] {
            updater.debugIndicatorPhase = phase
            updater.syncFlowPhase()
        }
        updater.automaticInstallInFlight = true
        updater.debugIndicatorPhase = .note(.checkFailed)
        updater.syncFlowPhase()
        #expect(abandoned == 1, "a failed automatic install did not unfreeze the windows")
        #expect(!updater.automaticInstallInFlight)
    }
}
