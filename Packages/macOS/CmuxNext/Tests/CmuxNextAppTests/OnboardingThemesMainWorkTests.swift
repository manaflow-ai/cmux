@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
import CmuxNextTerminal
import CmuxNextWakeups
import Foundation
import Testing

/// p06-scheduler-315, the FG sweep of CmuxNextApp/Onboarding and Themes (rule 9): the theme files are read on
/// the files lane and land as one posted task each (Chrome's PostTaskAndReply, base/task/thread_pool.h), never
/// in the caller's turn nor as an unclassed main-actor resume; the day, time zone and clock notices reach the
/// terminal setting through the app's one AppEvents observer, not an observer of its own.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct OnboardingThemesMainWorkTests {
    /// What a callback saw (a main-actor box a `@Sendable` closure can hold).
    @MainActor private final class Seen {
        var value: String?
        var calls = 0
    }

    private static func scratch(_ name: String, json: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-p06-315-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name)
        try Data(json.utf8).write(to: url)
        return url
    }

    @Test func aWorkspaceBackgroundFileLandsAsOnePostedTaskOffTheCallersTurn() throws {
        let url = try Self.scratch("workspace-backgrounds.json", json: #"{"home/ws-1":"none"}"#)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = WorkspaceBackgroundStore(url: url)
        store.load(on: BackgroundWork(label: "test.p06-315.backgrounds"), replyingOn: linklessMainWork())
        #expect(store.backgrounds.isEmpty, "nothing merges in the caller's turn")
        #expect(runMainLoop { store.background(for: "home/ws-1") == "none" }, "the read lands as the reply's task")
    }

    @Test func aTerminalThemeFileLandsBeforeItsCallerRunsAndKeepsAnEarlierPick() throws {
        let url = try Self.scratch("terminal-themes.json", json: #"{"m:saved":"Nord","m:picked":"Nord"}"#)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = TerminalThemeStore(url: url)
        store.set("Dracula", for: "m:picked")
        let seen = Seen()
        store.load(on: BackgroundWork(label: "test.p06-315.terminal-themes"), replyingOn: linklessMainWork()) {
            seen.value = store.theme(for: "m:saved")
            seen.calls += 1
        }
        #expect(seen.calls == 0, "the caller's callback waits for the read")
        #expect(runMainLoop { seen.calls == 1 })
        #expect(seen.value == "Nord", "the entries merged before the callback ran")
        #expect(store.theme(for: "m:picked") == "Dracula", "a theme set before the file loaded wins")
    }

    @Test func aStoreWithNoFileCallsBackAtOnce() {
        let store = TerminalThemeStore(url: nil)
        let seen = Seen()
        store.load(on: BackgroundWork(label: "test.p06-315.no-file"), replyingOn: linklessMainWork()) { seen.calls += 1 }
        #expect(seen.calls == 1)
    }

    /// The catalog's reload returns once its pass's names and colors landed on main, read on the files lane.
    @Test func aCatalogReloadReturnsWithThePassLanded() async {
        let catalog = ThemeCatalog(work: BackgroundWork(label: "test.p06-315.catalog"), mainWork: linklessMainWork())
        let reads = Seen()
        catalog.onRead = { reads.calls += 1 }
        await catalog.reload()
        let environment = ProcessInfo.processInfo.environment, home = FileManager.default.homeDirectoryForCurrentUser
        let resources = GhosttyRuntime.resourcesDirectory()
        #expect(catalog.names == ThemeCatalog.list(resources: resources, home: home, environment: environment))
        #expect(catalog.colors.count == ThemeCatalog.read(resources: resources, home: home, environment: environment).colors.count)
        #expect(reads.calls == 1, "one landed pass, one read callback")
    }

    /// The terminal setting hears day, time zone and clock changes through the injected AppEvents: one subscription per
    /// notice on the app's one observer, released with the setting.
    @Test func theDayNoticesAreSubscriptionsOnTheAppsOneObserver() async throws {
        let url = try Self.scratch("cmux.json", json: "{}")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        let events = AppEvents(center: NotificationCenter())
        var terminal: TerminalThemeSetting? = TerminalThemeSetting(backdropScope: ThemeScope(level: .room),
                                                                   deadlines: MainDeadlineScheduler(work: linklessMainWork()), appEvents: events)
        terminal?.reload = {}
        terminal?.follow(settings)
        for name in [Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange, .NSSystemClockDidChange] {
            #expect(events.subscriberCount(name) == 1, "\(name.rawValue)")
        }
        terminal = nil
        #expect(!events.isObserving(.NSSystemClockDidChange), "the subscriptions go with the setting")
    }
}
