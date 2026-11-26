import AppKit
import CmuxNextDesign
import CmuxNextTestSupport
import Foundation
@testable import CmuxNextUpdater
import Testing

/// Restart to Update (incident 2026-10-20, #22919): the windows left the screen at the click, and a
/// click whose install never reached the installer kept them invisible for 7 s. They now leave when
/// Sparkle commits to the relaunch. Review of #22919 at c0756ab, finding 2: that hook also runs for
/// an install nobody clicked (Sparkle's automatic driver, the relaunch behind the person's app), whose
/// failures bring nothing back, so only a relaunch the person asked for hides the windows, and a
/// relaunch behind that does not quit brings them back.
@MainActor @Suite(.serialized) struct UpdateRelaunchHandoffTests {
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

    @Test func aClickedInstallHidesTheWindowsWhenSparkleCommitsToTheRelaunch() {
        let updater = Self.updater()
        var relaunches = 0, hides = 0
        updater.willRelaunch = { relaunches += 1 }
        updater.hidesForRelaunch = { hides += 1 }
        updater.automaticInstallInFlight = false
        updater.updaterWillRelaunchApplication()
        #expect(relaunches == 1)
        #expect(hides == 1, "the relaunch the person clicked for left the windows on screen")
    }

    @Test func anInstallNobodyClickedNeverHidesTheWindows() {
        let updater = Self.updater()
        var relaunches = 0, hides = 0
        updater.willRelaunch = { relaunches += 1 }
        updater.hidesForRelaunch = { hides += 1 }
        updater.automaticInstallInFlight = true
        updater.updaterWillRelaunchApplication()
        #expect(relaunches == 1, "the relaunch still keeps every session")
        #expect(hides == 0, "an automatic install hid the windows, and its failure would never bring them back")
    }

    @Test func aRelaunchBehindThatDoesNotQuitBringsTheWindowsBack() {
        let updater = Self.updater()
        var abandoned = 0
        updater.installAbandoned = { abandoned += 1 }
        updater.automaticInstallInFlight = true
        updater.quitForInstallDeclined()
        #expect(abandoned == 1, "the app kept running after its relaunch-behind quit was declined, with no restore")
        #expect(!updater.automaticInstallInFlight)
    }

    /// Review of #22919 at 0088e20, finding 3: an automatic install that fails after it began to
    /// install brings back any window the relaunch took off the screen.
    @Test func anAutomaticInstallThatFailsBringsTheWindowsBack() {
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
        #expect(abandoned == 1, "a failed automatic install did not bring the windows back")
        #expect(!updater.automaticInstallInFlight)
    }
    /// Leo, 2026-11-24: "it def percievably changed a lot bc the agent pane blanked". The quit pictured the chats only
    /// from windows on screen, after the handoff had ordered them out, so it found none and dropped every saved page:
    /// the relaunched agent panes had no picture to draw. The pages' save runs while the windows are still on screen,
    /// they leave once it ended, and the quit awaits that same save (``UpdaterService/savedForRelaunch``).
    @Test func thePagesArePicturedBeforeTheWindowsLeave() async {
        _ = NSApplication.shared
        let updater = Self.updater()
        let handoff = UpdateWindowHandoff(unsaved: QuitUnsavedRegistry())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 160), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        var onScreenAtSave: Bool?
        handoff.savesBeforeLeaving = { onScreenAtSave = window.isVisible }
        handoff.attach(to: updater)
        #expect(handoff.hide())
        let saved = updater.savedForRelaunch
        #expect(saved != nil, "the quit has no relaunch save to await, and would picture windows already off screen")
        await saved?.value
        for _ in 0..<20 where window.isVisible { await Task.yield() }
        #expect(onScreenAtSave == true, "the pages were pictured after their windows left the screen")
        #expect(!window.isVisible, "the windows stayed on screen after the save")
        handoff.restore()
        #expect(updater.savedForRelaunch == nil, "a relaunch that did not happen left its save for the next quit")
    }
}
