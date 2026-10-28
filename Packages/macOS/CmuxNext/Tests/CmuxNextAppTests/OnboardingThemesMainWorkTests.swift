import AppKit
@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
import CmuxNextTerminal
import CmuxNextWakeups
import Foundation
import Observation
import Testing

/// The FG sweep of CmuxNextApp/Onboarding and Themes (rule 9): the theme files are read on
/// the files lane and land as one posted task each (Chrome's PostTaskAndReply, base/task/thread_pool.h), in the
/// caller's class; the terminal setting follows the settings as a ServiceObservation (a person's change applies in
/// the input-response pass, a script's yields to input, and its side effects run with no view on screen), hears the
/// day, time zone, clock and wake notices through the app's one observer per notice, and coalesces a background
/// drag's reloads on one MainDeadline; the classic import's waits are ObservedConditions.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct OnboardingThemesMainWorkTests {
    /// What a callback saw (a main-actor box a `@Sendable` closure can hold).
    @MainActor private final class Seen {
        var value: String?
        var calls = 0
        var repaints = 0
        var result: Bool?
        var classes: [MainWorkClass?] = []
    }

    private static func scratch(_ name: String, json: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-p06-315-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name)
        try Data(json.utf8).write(to: url)
        return url
    }

    private static func settings(_ json: String = "{}") async throws -> (SettingsController, URL) {
        let url = try scratch("cmux.json", json: json)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        return (settings, url)
    }

    private static func descriptor(_ key: String) throws -> SettingDescriptor {
        try #require(SettingsSchema.descriptor(for: key.split(separator: ".").map(String.init)))
    }

    /// A terminal setting on `deadlines`, hearing app and workspace notices on `center` (the caller keeps it).
    private static func terminal(_ scope: ThemeScope, deadlines: MainDeadlineScheduler, center: NotificationCenter) -> TerminalThemeSetting {
        TerminalThemeSetting(backdropScope: scope, deadlines: deadlines, appEvents: AppEvents(center: center),
                             workspaceEvents: AppEvents(center: center))
    }

    // MARK: File loads (BackgroundWork replies)

    @Test func aWorkspaceBackgroundFileLandsAsOnePostedTaskOffTheCallersTurn() throws {
        let url = try Self.scratch("workspace-backgrounds.json", json: #"{"home/ws-1":"none"}"#)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let work = BackgroundWork(label: "test.p06-315.backgrounds")
        let store = WorkspaceBackgroundStore(url: url, runner: work)
        store.load(on: work, replyingOn: linklessMainWork())
        #expect(store.backgrounds.isEmpty, "nothing merges in the caller's turn")
        #expect(runMainLoop { store.background(for: "home/ws-1") == "none" }, "the read lands as the reply's task")
    }

    @Test func aTerminalThemeFileLandsBeforeItsCallerRunsAndKeepsAnEarlierPick() throws {
        let url = try Self.scratch("terminal-themes.json", json: #"{"m:saved":"Nord","m:picked":"Nord"}"#)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let work = BackgroundWork(label: "test.p06-315.terminal-themes")
        let store = TerminalThemeStore(url: url, runner: work)
        store.set("Dracula", for: "m:picked")
        let seen = Seen()
        store.load(on: work, replyingOn: linklessMainWork()) {
            seen.value = store.theme(for: "m:saved")
            seen.calls += 1
        }
        #expect(seen.calls == 0, "the caller's callback waits for the read")
        #expect(runMainLoop { seen.calls == 1 })
        #expect(seen.value == "Nord", "the entries merged before the callback ran")
        #expect(store.theme(for: "m:picked") == "Dracula", "a theme set before the file loaded wins")
    }

    @Test func aStoreWithNoFileCallsBackAtOnce() {
        let work = BackgroundWork(label: "test.p06-315.no-file")
        let store = TerminalThemeStore(url: nil, runner: work)
        let seen = Seen()
        store.load(on: work, replyingOn: linklessMainWork()) { seen.calls += 1 }
        #expect(seen.calls == 1)
    }

    /// The catalog's reload returns once its pass's names and colors landed on main, read on the files lane.
    @Test func aCatalogReloadReturnsWithThePassLanded() async {
        let catalog = ThemeCatalog(work: BackgroundWork(label: "test.p06-315.catalog"), mainWork: linklessMainWork())
        let reads = Seen()
        catalog.onRead = { reads.calls += 1 }
        await catalog.reload(.userBlocking)
        let environment = ProcessInfo.processInfo.environment, home = FileManager.default.homeDirectoryForCurrentUser
        let resources = GhosttyRuntime.resourcesDirectory()
        #expect(catalog.names == ThemeCatalog.list(resources: resources, home: home, environment: environment))
        #expect(catalog.colors.count == ThemeCatalog.read(resources: resources, home: home, environment: environment).colors.count)
        #expect(reads.calls == 1, "one landed pass, one read callback")
    }

    /// p06 rule 2: a person's theme import waits on the reload, so both of its replies run as `userBlocking` tasks on
    /// the turn they reach main, with no frame; the launch's `visible` pass waits for the frames that show it.
    @Test func aPersonsCatalogReloadLandsInUserBlockingAndTheLaunchPassInVisible() async {
        let harness = FollowerHarness()
        defer { harness.stop() }
        let catalog = ThemeCatalog(work: BackgroundWork(label: "test.p06-315.catalog-person"), mainWork: harness.work)
        let seen = Seen()
        catalog.onRead = { seen.classes.append(harness.work.budget.board.running?.workClass) }
        let reload = Task {
            seen.value = "started"
            await catalog.reload(.userBlocking)
            seen.calls += 1
        }
        // The task starts its pass before it first suspends.
        while seen.value == nil { await Task.yield() }
        #expect(runMainLoop { !seen.classes.isEmpty }, "the person's reload waited for a frame")
        await reload.value
        #expect(seen.calls == 1)
        #expect(seen.classes == [.userBlocking], "the person's reload landed outside one userBlocking task")

        let launch = ThemeCatalog(work: BackgroundWork(label: "test.p06-315.catalog-launch"), mainWork: harness.work)
        let launchSeen = Seen()
        launch.onRead = { launchSeen.classes.append(harness.work.budget.board.running?.workClass) }
        launch.load()
        #expect(runMainLoop { harness.work.postedCount(.visible) == 1 }, "the names wait for a frame as one visible task")
        #expect(launchSeen.classes.isEmpty)
        harness.frame()
        #expect(runMainLoop { harness.work.postedCount(.visible) == 1 }, "the colors wait for a frame as one visible task")
        harness.frame()
        #expect(launchSeen.classes == [.visible])
    }

    // MARK: TerminalThemeSetting (AppEvents, ServiceObservation, MainDeadline)

    /// The terminal setting hears day, time zone, clock and wake notices through the injected AppEvents: one
    /// subscription per notice on the app's one observer, released with the setting.
    @Test func theDayAndWakeNoticesAreSubscriptionsOnTheAppsOneObserver() async throws {
        let (settings, url) = try await Self.settings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let center = NotificationCenter()
        let events = AppEvents(center: center), workspace = AppEvents(center: center)
        var terminal: TerminalThemeSetting? = TerminalThemeSetting(backdropScope: ThemeScope(level: .room),
                                                                   deadlines: MainDeadlineScheduler(work: linklessMainWork()),
                                                                   appEvents: events, workspaceEvents: workspace)
        terminal?.reload = {}
        terminal?.follow(settings)
        withExtendedLifetime(center) {
            for name in [Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange, .NSSystemClockDidChange] {
                #expect(events.subscriberCount(name) == 1, "\(name.rawValue)")
            }
            #expect(workspace.subscriberCount(NSWorkspace.didWakeNotification) == 1, "the wake re-picks a shuffle")
            terminal = nil
            #expect(!events.isObserving(.NSSystemClockDidChange), "the subscriptions go with the setting")
            #expect(!workspace.isObserving(NSWorkspace.didWakeNotification))
        }
    }

    /// Rule 9, person: a person's background preview reaches the window's scope in the input-response pass, before
    /// the commit and with their next input pending; its posted task then applies nothing more.
    @Test func aPersonsBackgroundPreviewAppliesInTheInputResponsePass() async throws {
        let (settings, url) = try await Self.settings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let harness = FollowerHarness(), center = NotificationCenter(), scope = ThemeScope(level: .room)
        defer { harness.stop() }
        let terminal = Self.terminal(scope, deadlines: MainDeadlineScheduler(work: harness.work), center: center)
        terminal.reload = {}
        terminal.follow(settings)
        let work = "van-gogh-starry-night"
        let descriptor = try Self.descriptor("appearance.background")
        harness.input.pending = true
        harness.work.causes.withCause(.person) { _ = settings.preview(descriptor, .string(work)) }
        #expect(scope.backdropSelection?.id != work, "nothing applies inside the change")
        #expect(harness.work.causes.flushPersonCaused() == 1, "the pass applies the person's change")
        #expect(scope.backdropSelection?.id == work, "applied before the commit, with input pending")
        harness.frame()
        harness.frame()
        #expect(scope.backdropSelection?.id == work)
        settings.endPreview()
        withExtendedLifetime((terminal, center)) {}
    }

    /// Rule 9, automation and hidden: a script's theme change yields one frame to the person's pending input, then
    /// applies; the setting has no node, so its side effect (the Ghostty reload) runs with no window on screen.
    @Test func aScriptsThemeChangeYieldsToInputThenReloadsWithNothingShown() async throws {
        let (settings, url) = try await Self.settings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let harness = FollowerHarness(), center = NotificationCenter(), seen = Seen()
        defer { harness.stop() }
        let terminal = Self.terminal(ThemeScope(level: .room), deadlines: MainDeadlineScheduler(work: harness.work), center: center)
        terminal.reload = { seen.calls += 1 }
        terminal.follow(settings)
        let before = seen.calls
        let descriptor = try Self.descriptor("appearance.theme")
        harness.input.pending = true
        harness.work.causes.withCause(.automation) { _ = settings.preview(descriptor, .string("Rose Pine")) }
        #expect(harness.work.causes.flushPersonCaused() == 0, "a script's change is not the person's")
        harness.frame()
        #expect(seen.calls == before, "the script's change waited behind the pending input")
        #expect(GhosttyRuntime.themeOverride != "Rose Pine")
        harness.frame()
        #expect(GhosttyRuntime.themeOverride == "Rose Pine", "it applies on the next frame, input still pending")
        #expect(seen.calls == before + 1, "the reload ran with no view on screen")
        settings.endPreview()
        harness.frame()
        harness.frame()
        withExtendedLifetime((terminal, center)) {}
    }

    /// The Opacity slider's steps repaint at once and reload Ghostty once, on the reload MainDeadline after the last
    /// step, not once per step.
    @Test func anOpacityDragReloadsOnceAfterItsLastStep() async throws {
        let (settings, url) = try await Self.settings(#"{"appearance":{"backgroundOpacity":0.5}}"#)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        GhosttyConfigBackground.loaded = GhosttyConfigBackground()
        defer { GhosttyRuntime.backgroundOverride = WindowBackgroundOverride() }
        let rig = MainDeadlineRig(), center = NotificationCenter(), seen = Seen()
        let terminal = Self.terminal(ThemeScope(level: .room), deadlines: rig.deadlines, center: center)
        terminal.reload = { seen.calls += 1 }
        terminal.repaint = { seen.repaints += 1 }
        terminal.follow(settings)
        let descriptor = try Self.descriptor("appearance.backgroundOpacity")
        // The first step may change the window's material (a linked edit), which reloads at once.
        #expect(settings.preview(descriptor, .number(0.6)))
        rig.frame()
        let (reloads, repaints) = (seen.calls, seen.repaints)
        for step in [0.7, 0.8, 0.9] {
            #expect(settings.preview(descriptor, .number(step)))
            rig.frame()
        }
        #expect(seen.repaints == repaints + 3, "every step repaints the window at once")
        #expect(seen.calls == reloads, "no step reloads Ghostty")
        #expect(rig.hasArmedWake, "the reload waits on its deadline")
        rig.fireAndRun()
        #expect(seen.calls == reloads + 1, "one reload after the last step")
        #expect(!rig.hasArmedWake)
        settings.endPreview()
        withExtendedLifetime((terminal, center)) {}
    }

    // MARK: ObservedCondition (ClassicMigration.awaitStore, ClassicImport.sshConnect)

    /// The classic import's two waits, by the seam each instance method calls.
    enum ClassicWait: CaseIterable, Sendable {
        case store, sshConnect

        var limit: Duration {
            switch self {
            case .store: AppOnboardingServices.classicStoreWaitLimit
            case .sshConnect: AppOnboardingServices.sshConnectLimit
            }
        }

        /// Waits on the rig; returns whether `ready` holds when the wait ends.
        @MainActor func wait(_ rig: MainDeadlineRig, _ ready: @escaping @MainActor () -> Bool) async -> Bool {
            switch self {
            case .store:
                return await AppOnboardingServices.awaitStore(on: rig.deadlines.work, deadlines: rig.deadlines, ready)
            case .sshConnect:
                await AppOnboardingServices.awaitConnections(on: rig.deadlines.work, deadlines: rig.deadlines, ready)
                return ready()
            }
        }
    }

    @Test(arguments: ClassicWait.allCases)
    func aClassicWaitThatHoldsNowArmsNothing(_ kind: ClassicWait) async {
        let rig = MainDeadlineRig()
        let holds = await kind.wait(rig) { true }
        #expect(holds)
        #expect(!rig.hasArmedWake, "a satisfied wait armed its timeout")
    }

    @Test(arguments: ClassicWait.allCases)
    func aClassicWaitEndsOnTheFrameAfterItsConditionHolds(_ kind: ClassicWait) async {
        let rig = MainDeadlineRig(), flag = OnboardingWaitFlag()
        let waiter = Task { await kind.wait(rig) { flag.isOn } }
        while !rig.hasArmedWake { await Task.yield() }
        flag.isOn = true
        rig.frame()
        #expect(await waiter.value)
        #expect(!rig.hasArmedWake, "the timeout stayed armed after the condition held")
        #expect(rig.elapsed == 0, "the wait ended on the change, not on its bound")
    }

    @Test(arguments: ClassicWait.allCases)
    func aClassicWaitWhoseConditionNeverHoldsEndsAtItsBound(_ kind: ClassicWait) async {
        let rig = MainDeadlineRig(), flag = OnboardingWaitFlag()
        let waiter = Task { await kind.wait(rig) { flag.isOn } }
        while !rig.hasArmedWake { await Task.yield() }
        rig.fireAndRun()
        #expect(await waiter.value == false)
        let bound = Double(kind.limit.components.seconds)
        #expect(rig.elapsed >= bound, "the wait ended \(rig.elapsed) s in, before its \(bound) s bound")
    }

    @Test(arguments: ClassicWait.allCases)
    func aCancelledClassicWaitResumesAndDisarmsItsBound(_ kind: ClassicWait) async {
        let rig = MainDeadlineRig(), flag = OnboardingWaitFlag(), seen = Seen()
        let waiter = Task {
            let holds = await kind.wait(rig) { flag.isOn }
            seen.result = holds
            return holds
        }
        while !rig.hasArmedWake { await Task.yield() }
        waiter.cancel()
        // The cancel posts the end from any thread: it reaches main on a run loop pass, then runs on a frame.
        let end = Date(timeIntervalSinceNow: 5)
        while seen.result == nil, Date() < end {
            runMainLoopPass(for: 0.01)
            rig.frame()
        }
        #expect(await waiter.value == false)
        #expect(!rig.hasArmedWake, "a cancelled wait left its timeout armed")
    }
}

/// The condition a classic wait reads.
@MainActor @Observable
private final class OnboardingWaitFlag {
    var isOn = false
}
