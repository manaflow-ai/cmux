import AppKit
@testable import CmuxNextApp
import CmuxNextActions
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

        init(_ authorization: String, answer: Bool = false, sound: Bool = true) {
            current = NotificationPermission(authorization: authorization, alert: false, alertStyle: "none", sound: sound, badge: false,
                                             bundleID: "com.cmuxterm.app.nightly")
            self.answer = answer
        }

        func status() async -> NotificationPermission { current }

        func request() async throws -> NotificationPermission {
            requests += 1
            if current.authorization == "not_determined" { current.authorization = answer ? "authorized" : "denied" }
            return current
        }
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

    @Test func aDeniedRefreshUpdatesTheCardAndTellsThePerson() async {
        let desktop = DesktopNotifier()
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

    @Test func notYetAskedIsAskedOnce() async {
        let desktop = DesktopNotifier()
        let center = FakeCenter("not_determined", answer: true)
        desktop.permissionCenterOverride = center
        await desktop.refreshPermission()
        await desktop.refreshPermission()
        #expect(await center.requests == 1)
        #expect(desktop.authorization == "authorized")
        #expect(desktop.permissionState.bannersCarrySound)
    }

    @Test func aDefaultSoundBannerPlaysInTheAppWhileDenied() {
        let desktop = DesktopNotifier()
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
            _ = try await page.call("cmux.settings.sound.play", params: ["name": .string(name)],
                                    context: PageCallContext(page: "cmux.settings", userGesture: true))
        }
        #expect(played == ["default", "Glass"], "Default is played, not skipped")
    }
}
