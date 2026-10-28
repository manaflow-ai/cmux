@testable import CmuxNextApp
import CmuxNextSettings
import Testing

/// `notifications.dockBounce`: an alert that arrives while cmux is not the
/// active app bounces the Dock icon once by default; the setting can make it
/// bounce until the user switches to cmux, or not at all.
struct DockBouncePolicyTests {
    private static func decide(_ mode: DockBounceMode = .once, appActive: Bool = false, muted: Bool = false,
                               desktop: DesktopNotificationMode = .unlessFocused) -> NotificationPolicy.Decision {
        var prefs = NotificationPreferences()
        prefs.dockBounce = mode
        prefs.desktop = desktop
        var arrival = NotificationPolicy.Arrival(source: .agent)
        arrival.appActive = appActive
        arrival.workspaceMuted = muted
        return NotificationPolicy(prefs: prefs).decide(arrival)
    }

    @Test func anAlertWhileInactiveBouncesOnceByDefault() {
        #expect(NotificationPreferences().dockBounce == .once)
        #expect(Self.decide().bounce == .once)
    }

    @Test func untilActiveKeepsBouncing() {
        #expect(Self.decide(.untilActive).bounce == .untilActive)
    }

    @Test func offNeverBounces() {
        #expect(Self.decide(.off).bounce == nil)
    }

    @Test func anActiveAppNeverBounces() {
        #expect(Self.decide(.untilActive, appActive: true).bounce == nil)
    }

    @Test func aNotificationThatDoesNotAlertDoesNotBounce() {
        #expect(Self.decide(muted: true).bounce == nil)
        #expect(Self.decide(desktop: .never).bounce == nil)
    }

    @Test func aPosterAskingForNoBannerGetsNoBounce() {
        var arrival = NotificationPolicy.Arrival(source: .cli)
        arrival.bannerAllowed = false
        #expect(NotificationPolicy(prefs: NotificationPreferences()).decide(arrival).bounce == nil)
    }

    @Test func quietHoursDoNotBounce() {
        var prefs = NotificationPreferences()
        prefs.dockBounce = .untilActive
        prefs.quietHours = QuietHours(start: 22 * 60, end: 7 * 60)
        var arrival = NotificationPolicy.Arrival(source: .agent)
        arrival.minuteOfDay = 23 * 60
        #expect(NotificationPolicy(prefs: prefs).decide(arrival).bounce == nil)
        arrival.minuteOfDay = 12 * 60
        #expect(NotificationPolicy(prefs: prefs).decide(arrival).bounce == .untilActive)
    }

    @Test func theSettingLoadsFromCmuxJSON() {
        let root: JSONValue = .object(["notifications": .object(["dockBounce": .string("untilActive")])])
        #expect(CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: []).notifications.dockBounce == .untilActive)
        let bad: JSONValue = .object(["notifications": .object(["dockBounce": .string("loud")])])
        let snapshot = CmuxConfigSnapshot.parse(bad, validDensities: [], validMetrics: [])
        #expect(snapshot.notifications.dockBounce == .once)
        #expect(snapshot.diagnostics.contains { $0.path == "notifications.dockBounce" })
    }

    @Test func onlyThePersonSetsIt() throws {
        let row = try #require(SettingsSchema.descriptor(for: ["notifications", "dockBounce"]))
        #expect(row.defaultValue == .string("once"))
        #expect(SettingsSchema.agentRefusedKeys["notifications.dockBounce"] == .userOnly)
    }
}
