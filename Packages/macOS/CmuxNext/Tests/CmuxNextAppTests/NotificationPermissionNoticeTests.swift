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

/// cmux#55600: macOS denied cmux NIGHTLY notifications, 28 banners and every finish sound were dropped,
/// and nothing in cmux said so. The permission is read into an observed state (Settings > Notifications'
/// card), a denial is told once, not yet asked is asked, and a "default" sound a denied banner cannot
/// carry plays in the app.
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

    @MainActor private final class Recorder: NotificationSoundPlaying {
        var played: [(name: String, banner: Bool)] = []
        func play(_ name: String, volume: Double, banner: Bool) { played.append((name, banner)) }
    }

    /// A notifier whose one-time notice writes to its own defaults, never the test host's.
    private func notifier() throws -> (DesktopNotifier, UserDefaults) {
        let defaults = try #require(UserDefaults(suiteName: "cmux-55600-\(UUID().uuidString)"))
        let desktop = DesktopNotifier()
        desktop.deniedNotice = NotificationDeniedNotice(defaults: defaults)
        return (desktop, defaults)
    }

    private static func permission(_ authorization: String, sound: Bool = true) -> NotificationPermission {
        NotificationPermission(authorization: authorization, alert: authorization == "authorized", alertStyle: "banner", sound: sound,
                               badge: false, bundleID: nil)
    }

    @Test func aRealPlayerSoundsADeniedDefaultBannerOnceAndAnAllowedOneNever() throws {
        let (desktop, _) = try notifier()
        let recorder = Recorder()
        let gate = NotificationSoundGate(player: recorder)
        _ = desktop.followPermission(sounds: gate, volume: { 1 }, asks: false) { nil }
        desktop.applyPermission(Self.permission("denied"))
        desktop.post(id: "cmux-notification-10", title: "Claude", body: "Finished", surface: nil, workspace: nil, defaultSound: true)
        #expect(recorder.played.count == 1, "exactly one play: the app's, since macOS drops the banner and its sound")
        #expect(recorder.played.first?.name == "default")
        #expect(recorder.played.first?.banner == false)
        desktop.applyPermission(Self.permission("authorized"))
        desktop.post(id: "cmux-notification-11", title: "Claude", body: "Finished", surface: nil, workspace: nil, defaultSound: true)
        #expect(recorder.played.count == 1, "an allowed banner sounds itself; the app adds nothing")
    }

    @Test func aShowcaseNeverReadsThePermission() async throws {
        let (desktop, _) = try notifier()
        let center = FakeCenter("denied")
        desktop.permissionCenterOverride = center
        _ = desktop.followPermission(sounds: NotificationSoundGate(player: Recorder()), volume: { 1 }, asks: false) { nil }
        await desktop.refreshPermission(asking: false) // what an activation runs
        #expect(await center.reads == 0, "the card never shows the host Mac's permission in a capture")
        #expect(desktop.authorization == "unknown" || desktop.authorization == "automation")
    }

    @Test func anOlderReadFinishingLateNeverOverwritesANewerOne() throws {
        let (desktop, _) = try notifier()
        desktop.applyPermission(Self.permission("authorized"), read: 5)
        desktop.applyPermission(Self.permission("denied"), read: 3)
        #expect(desktop.authorization == "authorized")
        desktop.applyPermission(Self.permission("denied"))
        #expect(desktop.authorization == "denied", "a fresh read (the Settings button's) is newest")
    }

    @Test func allowingAgainThroughARefreshReArmsTheNotice() async throws {
        let (desktop, defaults) = try notifier()
        var told = 0
        desktop.onDenied = { if desktop.deniedNotice.claim(for: desktop.authorization) { told += 1 } }
        let denied = FakeCenter("denied")
        desktop.permissionCenterOverride = denied
        await desktop.refreshPermission(asking: false)
        await desktop.refreshPermission(asking: false)
        #expect(told == 1, "told once per denial")
        desktop.permissionCenterOverride = FakeCenter("authorized")
        await desktop.refreshPermission(asking: false)
        #expect(defaults.object(forKey: NotificationDeniedNotice.shownKey) == nil, "allowed again: re-armed")
        desktop.permissionCenterOverride = denied
        await desktop.refreshPermission(asking: false)
        #expect(told == 2, "denied again: told again")
    }

    @Test func onlyABannerMacOSShowsAndSoundsCarriesTheDefaultSound() {
        #expect(NotificationPermissionState.bannersCarrySound(authorization: "authorized", sound: true))
        #expect(NotificationPermissionState.bannersCarrySound(authorization: "unknown", sound: nil))
        #expect(NotificationPermissionState.bannersCarrySound(authorization: "automation", sound: nil))
        #expect(!NotificationPermissionState.bannersCarrySound(authorization: "authorized", sound: false))
        for silent in ["denied", "not_determined", "provisional"] {
            #expect(!NotificationPermissionState.bannersCarrySound(authorization: silent, sound: true), "\(silent)")
        }
    }

    @Test func aDeniedRefreshUpdatesTheCardAndTellsThePerson() async throws {
        let (desktop, _) = try notifier()
        let center = FakeCenter("denied")
        desktop.permissionCenterOverride = center
        var denied = 0
        desktop.onDenied = { denied += 1 }
        await desktop.refreshPermission()
        #expect(desktop.authorization == "denied")
        #expect(desktop.permissionState.needsAttention)
        #expect(desktop.permissionState.pageJSON == ["authorization": .string("denied"), "sound": .bool(true)])
        #expect(denied == 1)
        #expect(await center.requests == 0, "a denial is never asked again: only System Settings undoes it")
    }

    @Test func notYetAskedIsAskedOnce() async throws {
        let (desktop, _) = try notifier()
        let center = FakeCenter("not_determined", answer: true)
        desktop.permissionCenterOverride = center
        await desktop.refreshPermission()
        await desktop.refreshPermission()
        #expect(await center.requests == 1)
        #expect(desktop.authorization == "authorized")
        #expect(desktop.permissionState.bannersCarrySound)
    }

    @Test func aDefaultSoundBannerPlaysInTheAppWhileDenied() throws {
        let (desktop, _) = try notifier()
        var played = 0
        desktop.playsDefaultSound = { played += 1 }
        desktop.permissionState.update(NotificationPermission(authorization: "denied", alert: false, alertStyle: "none", sound: true, badge: false, bundleID: nil))
        desktop.post(id: "cmux-notification-1", title: "Claude", body: "Finished", surface: nil, workspace: nil, defaultSound: true)
        #expect(played == 1, "the finish sound plays though macOS drops the banner")
        desktop.post(id: "cmux-notification-2", title: "Claude", body: "Finished", surface: nil, workspace: nil, defaultSound: false)
        #expect(played == 1, "a silent banner plays nothing")
        desktop.permissionState.update(NotificationPermission(authorization: "authorized", alert: true, alertStyle: "banner", sound: true, badge: true, bundleID: nil))
        desktop.post(id: "cmux-notification-3", title: "Claude", body: "Finished", surface: nil, workspace: nil, defaultSound: true)
        #expect(played == 1, "an allowed banner plays its own sound")
    }

    @Test func theDeniedNoticeShowsOncePerDenial() throws {
        let suite = "cmux-55600-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let notice = NotificationDeniedNotice(defaults: defaults)
        #expect(!notice.claim(for: "not_determined"))
        #expect(notice.claim(for: "denied"))
        #expect(!notice.claim(for: "denied"), "told once")
        #expect(!notice.claim(for: "authorized"))
        #expect(notice.claim(for: "denied"), "allowed, then denied again: told again")
    }

    @Test func settingsSoundPlayButtonPlaysDefaultThroughTheApp() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-55600-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let settings = SettingsController(writer: TestSettingsWriter(), registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        let page = SettingsPageProvider(settings: settings)
        var played: [String] = []
        page.playSound = { played.append($0) }
        for name in ["default", "Glass"] {
            let params: JSONValue = ["name": .string(name)]
            _ = try await page.call("cmux.settings.sound.play", params: params,
                                    context: PageCallContext(page: "cmux.settings", userGesture: true))
        }
        #expect(played == ["default", "Glass"], "Default is played, not skipped")
    }
}
