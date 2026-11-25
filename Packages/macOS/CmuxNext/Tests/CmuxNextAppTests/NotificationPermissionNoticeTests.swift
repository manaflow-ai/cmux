import AppKit
@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextNotifications
import CmuxNextPages
@testable import CmuxNextSettings
import CmuxNextTestSupport
import Foundation
import Testing

/// cmux#55600: notification permission in the app. cmux reads it (Settings > Notifications' card) but never asks
/// on its own: only the person turning notifications on shows the macOS prompt, and a denial then is told with
/// Open System Settings. Until macOS allows cmux notifications, banners and every notification sound stay off.
@MainActor @Suite(.serialized) struct NotificationPermissionNoticeTests {
    actor FakeCenter: NotificationPermissionCenter {
        var current: NotificationPermission
        let answer: Bool
        private(set) var requests = 0
        private(set) var reads = 0

        init(_ authorization: String, answer: Bool = false, sound: Bool = true) {
            current = NotificationPermission(authorization: authorization, alert: false, alertStyle: "none", sound: sound, badge: false,
                                             bundleID: "com.cmuxterm.app.nightly")
            self.answer = answer
        }

        func status() async -> NotificationPermission {
            reads += 1
            return current
        }

        func request() async throws -> NotificationPermission {
            requests += 1
            if current.authorization == "not_determined" { current.authorization = answer ? "authorized" : "denied" }
            return current
        }
    }

    /// A center whose first read never answers (a stalled `notificationSettings()` at launch).
    actor StallingCenter: NotificationPermissionCenter {
        private(set) var reads = 0
        func status() async -> NotificationPermission {
            reads += 1
            if reads == 1 { try? await Task.sleep(for: .seconds(3600)) }
            return NotificationPermission(authorization: "denied", alert: false, alertStyle: "none", sound: true, badge: false, bundleID: nil)
        }
        func request() async throws -> NotificationPermission { await status() }
    }

    @MainActor private final class Recorder: NotificationSoundPlaying {
        var played: [(name: String, banner: Bool)] = []
        func play(_ name: String, volume: Double, banner: Bool) { played.append((name, banner)) }
    }

    private static func permission(_ authorization: String, sound: Bool = true) -> NotificationPermission {
        NotificationPermission(authorization: authorization, alert: authorization == "authorized", alertStyle: "banner", sound: sound,
                               badge: false, bundleID: nil)
    }

    /// A real player whose loads are recorded instead of played.
    private static func player() -> (NotificationSoundPlayer, () -> [String]) {
        final class Box { var loaded: [String] = [] }
        let box = Box()
        let player = NotificationSoundPlayer { name, _ in
            box.loaded.append(name)
            return NSSound(named: NSSound.Name("Tink"))?.copy() as? NSSound
        }
        return (player, { box.loaded })
    }

    @Test func launchAndActivationReadsNeverAskOrTell() async throws {
        for state in ["denied", "not_determined"] {
            let desktop = DesktopNotifier()
            let center = FakeCenter(state)
            desktop.permissionCenterOverride = center
            var told = 0
            desktop.onDenied = { told += 1 }
            await desktop.refreshPermission()
            await desktop.refreshPermission()
            #expect(desktop.authorization == state)
            #expect(await center.requests == 0, "cmux never shows the macOS prompt on its own (\(state))")
            #expect(told == 0, "nothing is shown to someone who never turned notifications on (\(state))")
        }
    }

    @Test func turningNotificationsOnAsksOnceAndTellsADenial() async throws {
        let desktop = DesktopNotifier()
        let center = FakeCenter("not_determined", answer: false)
        desktop.permissionCenterOverride = center
        var told = 0
        desktop.onDenied = { told += 1 }
        await desktop.turnOn()
        #expect(await center.requests == 1, "turning notifications on shows the macOS prompt")
        #expect(desktop.authorization == "denied")
        #expect(told == 1, "the person said no: the toast points at System Settings")
        await desktop.turnOn()
        #expect(await center.requests == 1, "macOS asks once; after a denial only System Settings undoes it")
        #expect(told == 2, "turning them on again while blocked tells the person again")
    }

    @Test func turningNotificationsOnWhileAllowedTellsNothing() async throws {
        let desktop = DesktopNotifier()
        let center = FakeCenter("not_determined", answer: true)
        desktop.permissionCenterOverride = center
        var told = 0
        desktop.onDenied = { told += 1 }
        await desktop.turnOn()
        #expect(desktop.authorization == "authorized")
        await desktop.turnOn()
        #expect(await center.requests == 1)
        #expect(told == 0)
    }

    @Test func settingsAllowButtonAsksAndADenialThereIsTold() async throws {
        let desktop = DesktopNotifier()
        desktop.permissionCenterOverride = FakeCenter("not_determined", answer: false)
        var told = 0
        desktop.onDenied = { told += 1 }
        try await desktop.allowFromSettings()
        #expect(desktop.authorization == "denied")
        #expect(told == 1)
    }

    @Test func soundsPlayOnlyWhileMacOSAllowsThem() {
        #expect(NotificationPermissionState.allowsSounds(authorization: "authorized", sound: true))
        #expect(NotificationPermissionState.allowsSounds(authorization: "unknown", sound: nil))
        #expect(NotificationPermissionState.allowsSounds(authorization: "automation", sound: nil))
        #expect(!NotificationPermissionState.allowsSounds(authorization: "authorized", sound: false), "Play sound off in System Settings")
        for silent in ["denied", "not_determined", "provisional"] {
            #expect(!NotificationPermissionState.allowsSounds(authorization: silent, sound: true), "\(silent)")
        }
    }

    @Test func previewsAndEventSoundsAreSilentUntilAllowed() {
        let desktop = DesktopNotifier()
        let (player, loaded) = Self.player()
        let gate = NotificationSoundGate(player: player)
        _ = desktop.followPermission(sounds: gate, asks: false) { nil }
        desktop.applyPermission(Self.permission("denied"))
        gate.preview("default", volume: 1)
        gate.preview("Glass", volume: 1)
        desktop.post(id: "cmux-notification-10", title: "Claude", body: "Finished", surface: nil, workspace: nil, defaultSound: true)
        #expect(loaded().isEmpty, "denied: no preview, no finish sound")
        desktop.applyPermission(Self.permission("authorized"))
        gate.preview("default", volume: 1)
        gate.preview("Glass", volume: 1)
        #expect(loaded() == [NotificationSoundPlayer.alertSoundName(), "Glass"], "allowed: previews play, Default included")
        desktop.post(id: "cmux-notification-11", title: "Claude", body: "Finished", surface: nil, workspace: nil, defaultSound: true)
        #expect(loaded().count == 2, "an allowed banner plays its own sound; the app adds nothing")
    }

    @Test func aShowcaseNeverReadsThePermission() async throws {
        let desktop = DesktopNotifier()
        let center = FakeCenter("denied")
        desktop.permissionCenterOverride = center
        _ = desktop.followPermission(sounds: NotificationSoundGate(player: Recorder()), asks: false) { nil }
        await desktop.refreshPermission() // what an activation runs
        await desktop.turnOn()
        #expect(await center.reads == 0, "the card never shows the host Mac's permission in a capture")
        #expect(desktop.authorization == "unknown" || desktop.authorization == "automation")
    }

    @Test func anOlderReadFinishingLateNeverOverwritesANewerOne() {
        let desktop = DesktopNotifier()
        desktop.applyPermission(Self.permission("authorized"), read: 5)
        desktop.applyPermission(Self.permission("denied"), read: 3)
        #expect(desktop.authorization == "authorized")
        desktop.applyPermission(Self.permission("denied"))
        #expect(desktop.authorization == "denied", "a fresh read (the Settings button's) is newest")
    }

    /// The dev build of cmux#55647 stayed "Checking…" while macOS said denied: the launch read stalled.
    @Test func aStalledLaunchReadIsReadAgainUntilOneLands() async throws {
        let desktop = DesktopNotifier()
        let center = StallingCenter()
        desktop.permissionCenterOverride = center
        desktop.launchRereads = (count: 40, delay: .milliseconds(50))
        _ = desktop.followPermission(sounds: NotificationSoundGate(player: Recorder()), asks: true) { nil }
        let deadline = ContinuousClock.now + .seconds(20)
        while desktop.authorization != "denied", ContinuousClock.now < deadline { await Task.yield() }
        #expect(desktop.authorization == "denied", "a later read lands although the first never answers")
        #expect(await center.reads < 40, "reads stop once one lands")
    }
}
