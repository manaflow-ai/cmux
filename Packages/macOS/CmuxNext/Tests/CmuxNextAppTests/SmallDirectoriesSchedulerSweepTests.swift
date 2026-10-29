import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextBrowserImport
@testable import CmuxNextApp
import CmuxNextCompat
@testable import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextHistory
import CmuxNextPages
import CmuxNextSettings
import CmuxNextWakeups
import Foundation
import Observation
import Testing

/// The CmuxNextApp small-directories sweep (plans/cmux-next/chrome-parity/p06-scheduler.md,
/// rule 9): one case per migrated owner class. The vault list resolves a theme change of a hidden vault once, on show;
/// a person's Copy Image ends in one userBlocking task and a script's in one automation task; a new tab the store
/// never lists ends the link move at its limit as the person's work; Search Tabs' change signal and the Passwords
/// page's export gate are service observations that flush on the frame with no page on screen; the project import's
/// bookkeeping is one automation task with no window. IconPickerWarmTests has the pick during the launch-idle prepare,
/// TerminalClipboardReadServiceTests the prompt of a tab in an occluded window.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct SmallDirectoriesSchedulerSweepTests {
    // MARK: Hidden: the vault list (VaultHostView)

    /// A theme change while the vault is hidden resolves no colors (no view apply); its show resolves them once, however
    /// many changes came while it was hidden.
    @Test func aThemeChangeOfAHiddenVaultResolvesItsColorsOnceOnShow() {
        _ = NSApplication.shared
        let vault = SessionVault(source: SweepVaultSource(), work: BackgroundWork(), copyText: { _ in }, openURL: { _ in })
        let host = VaultHostView(vault: vault, registry: ActionRegistry(), readsOnAppear: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 480), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        // The window's node reads visible (the window is never ordered in), so the vault's node follows only its own hide.
        _ = WindowVisibilitySource.of(window, read: { _ in .visible })
        window.contentView = host
        defer { window.contentView = nil; window.close() }

        let shown = host.colorResolves
        host.viewDidChangeEffectiveAppearance()
        #expect(host.colorResolves == shown + 1, "a shown vault did not resolve its colors on a theme change")

        host.isHidden = true
        let hidden = host.colorResolves
        host.viewDidChangeEffectiveAppearance()
        host.viewDidChangeEffectiveAppearance()
        #expect(host.colorResolves == hidden, "a hidden vault resolved its colors")
        host.isHidden = false
        #expect(host.colorResolves == hidden + 1, "the show resolved the hidden theme changes \(host.colorResolves - hidden) times (want 1)")
    }

    // MARK: Person and automation: Copy Image's end (BrowserHitHandlers.copyImage)

    /// A person's Copy Image loads and decodes off main; the pasteboard write is one userBlocking task.
    @Test func aPersonsCopyImageWritesThePasteboardInOneUserBlockingTask() async throws {
        let (services, pasteboard) = Self.copyImageServices()
        let tasks = services.registry.capturingWork {
            _ = services.registry.perform("browser.image.copy", invocation: ActionInvocation(arguments: ["url": .string(Self.pixel)]))
        }
        let task = try #require(tasks.first, "Copy Image reported no work to the capturing run")
        let failure = await Self.value(of: task)
        #expect(failure == nil, "Copy Image failed: \(failure?.message ?? "")")
        #expect(pasteboard.images == 1)
        #expect(Self.classes(of: "BrowserHitHandlers.copyImage", on: services) == [.userBlocking],
                "the person's Copy Image ended outside one userBlocking task")
    }

    /// A CLI's Copy Image ends in one automation task: it yields to the person's input.
    @Test func aCLIsCopyImageWritesThePasteboardInOneAutomationTask() async throws {
        let (services, pasteboard) = Self.copyImageServices()
        let tasks = services.registry.capturingWork {
            ActionRunScope.$current.withValue(ActionRunScope(origin: .cli, allowsViewChange: false)) {
                _ = services.registry.perform("browser.image.copy",
                                              invocation: ActionInvocation(arguments: ["url": .string(Self.pixel)], origin: .cli))
            }
        }
        let task = try #require(tasks.first, "Copy Image reported no work to the capturing run")
        #expect(await Self.value(of: task) == nil)
        #expect(pasteboard.images == 1)
        #expect(Self.classes(of: "BrowserHitHandlers.copyImage", on: services) == [.automation],
                "the CLI's Copy Image ended outside one automation task")
    }

    // MARK: Person: the link move's limit (LinkOpener.move)

    /// A new tab the store never lists ends the move at the limit, in one userBlocking task (the person's link), and
    /// the run answers why.
    @Test func aTabTheStoreNeverListsEndsTheMoveAtTheLimitAsThePersonsWork() async throws {
        _ = NSApplication.shared
        let rig = MainDeadlineRig()
        let services = AppServices(environment: AppEnvironment.current([:]), mainWork: rig.deadlines.work)
        services.daemon.store.apply(snapshot: Self.tree())
        let model = try #require(services.daemon.store.workspaces.first?.screens.first?.panes.first)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        let pane = PaneController(pane: model, daemon: services.daemon, layoutPaneID: LayoutPaneID(model.id), services: services,
                                  state: WindowState(record: record))
        defer { pane.teardown() }
        services.linkOpener.listLimit = .milliseconds(20)
        let tasks = services.registry.capturingWork {
            services.linkOpener.moveBeside(SurfaceID(rawValue: 9_320), from: pane, focus: false)
        }
        let task = try #require(tasks.first, "the move reported no work to the capturing run")
        let failure = await Self.value(of: task)
        #expect(failure?.message == "link open: the new tab did not open")
        #expect(Self.classes(of: "LinkOpener.tabListed", on: services) == [.userBlocking],
                "the person's move ended its wait outside one userBlocking task")
    }

    // MARK: Service observation: Search Tabs' change signal (AppTabSearchSource)

    /// A tab change signals Search Tabs on the scheduler's frame, not in the change's own turn, with no page on screen.
    @Test func aTabChangeSignalsSearchTabsOnTheFrameWithNoPageShown() async throws {
        _ = NSApplication.shared
        let rig = MainDeadlineRig()
        let services = AppServices(environment: AppEnvironment.current([:]), mainWork: rig.deadlines.work)
        let feed = ClosedTabsFeed(services: services)
        services.closedTabs = feed
        let source = AppTabSearchSource(services: services)
        let seen = SmallSweepSeen()
        let changes = source.changes()
        // task-owner: the test's one reader of the signal; it ends at the first one
        let reader = Task {
            for await _ in changes {
                seen.signals += 1
                break
            }
        }
        await Task.yield()
        feed.changes.bump()
        for _ in 0..<3 { await Task.yield() }
        #expect(seen.signals == 0, "the change signalled Search Tabs in its own turn")
        for _ in 0..<50 where seen.signals == 0 {
            rig.frame()
            await Task.yield()
        }
        await reader.value
        #expect(seen.signals == 1, "the change never signalled Search Tabs (the signal is a service observation)")
    }

    // MARK: Service observation: the Passwords page's export gate (PasswordsPageProvider)

    /// Turning export on tells the page on the scheduler's frame, with no page on screen: the page host keeps a hidden
    /// page's events, so the gate is a service and never waits for a show.
    @Test func turningExportOnTellsThePageOnTheFrameWithNoPageShown() async throws {
        let rig = MainDeadlineRig()
        let flag = SmallSweepFlag()
        let provider = PasswordsPageProvider(store: SamplePasswordStore(), profiles: { [.init(id: "default", name: "Default")] },
                                             confirmations: SweepPasswordPerson(), authenticator: SweepPasswordPerson(),
                                             secrets: SweepPasswordPerson(), mainWork: rig.deadlines.work)
        provider.allowExport = { flag.isOn }
        let seen = SmallSweepSeen()
        let subscription = try await provider.subscribe(PasswordOps.changed, filter: .null,
                                                        context: PageCallContext(page: "cmux.passwords", userGesture: false)) { _ in
            seen.signals += 1
        }
        defer { subscription.cancel() }
        #expect(seen.signals == 0, "the gate's first value told the page")
        flag.isOn = true
        #expect(seen.signals == 0, "the gate told the page in the change's own turn")
        rig.frame()
        #expect(seen.signals == 1, "the gate did not tell the page on the frame")
    }

    // MARK: Automation: the project import's bookkeeping (ProjectsImport.finished)

    /// The sends run off main, and their bookkeeping is one automation task: the daemon gets the projects with no
    /// window on screen, and the import never competes with the person's input.
    @Test func theProjectImportsBookkeepingIsOneAutomationTaskWithNoWindow() {
        _ = NSApplication.shared
        let rig = MainDeadlineRig()
        let services = AppServices(environment: AppEnvironment.current([:]), mainWork: rig.deadlines.work)
        let seen = SmallSweepSeen()
        let connection = NSObject()
        let sends = SweepSends()
        let importer = ProjectsImport(services: services) {
            ProjectsImport.Target(id: ObjectIdentifier(connection)) { _, fresh in
                sends.record(fresh: fresh)
                return ProjectsImport.Sent(synced: true, delivered: [:])
            }
        }
        importer.onFinished = { seen.classes.append(rig.deadlines.work.budget.board.running?.workClass) }
        #expect(services.windows.controllers.isEmpty, "the test is about an import with no window")
        importer.start(feed: nil)
        #expect(seen.classes.isEmpty, "the import's bookkeeping ran in its own turn, before the sends")
        hostPressureSpin(until: { !seen.classes.isEmpty }, rig: rig)
        #expect(sends.fresh == [true], "a fresh connection's relay did not sync first")
        #expect(seen.classes == [.automation], "the import's bookkeeping ran outside one automation task")
        withExtendedLifetime((services, connection)) {}
    }

    // MARK: Helpers

    /// A 1 x 1 PNG as a `data:` address: Copy Image loads it with no network.
    private static let pixel = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

    /// App services with the Copy actions bound to a recording pasteboard.
    private static func copyImageServices() -> (AppServices, SweepPasteboard) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let pasteboard = SweepPasteboard()
        BrowserHitHandlers.bindCopy(services.registry, AppActionContext(services: services)) { pasteboard }
        return (services, pasteboard)
    }

    /// `work`'s answer, with the main run loop running while it is awaited: the work's main-thread end is a task
    /// posted to the run loop, and its off-main part may wait for a run loop timer (a deadline).
    private static func value(of work: ActionWork) async -> ActionWorkFailure? {
        let answer = SmallSweepAnswer()
        // task-owner: the test's one read of the work's answer
        let reader = Task {
            answer.failure = await work.value
            answer.done = true
        }
        let end = Date(timeIntervalSinceNow: 5)
        while !answer.done, Date() < end {
            runMainLoopPass(for: 0.01)
            await Task.yield()
        }
        await reader.value
        return answer.failure
    }

    /// The classes `owner`'s tasks ran in, from the scheduler's owner ledger.
    private static func classes(of owner: String, on services: AppServices) -> [MainWorkClass] {
        services.mainWork.budget.board.ownerSnapshot().owners.filter { $0.owner == owner }.map(\.workClass)
    }

    private static func tree() -> DaemonTree {
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(PaneID(rawValue: 1)), panes: [pane])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w1", screens: [screen])])
    }
}

@MainActor
private final class SmallSweepSeen {
    var signals = 0
    var classes: [MainWorkClass?] = []
}

@MainActor
private final class SmallSweepAnswer {
    var failure: ActionWorkFailure?
    var done = false
}

@MainActor @Observable
private final class SmallSweepFlag {
    var isOn = false
}

/// What the project import's sends were asked, from off main.
private nonisolated final class SweepSends: Sendable {
    private let state = Mutex<[Bool]>([])

    var fresh: [Bool] { state.withLock { $0 } }

    func record(fresh: Bool) { state.withLock { $0.append(fresh) } }
}

/// The vault's sessions: none.
private final class SweepVaultSource: VaultSessionSource {
    func refresh() async {}
    func sessions() -> [AgentSession] { [] }
    func isLive(_ session: AgentSession) -> Bool { false }
}

/// Records what Copy writes, with no pasteboard server.
private nonisolated final class SweepPasteboard: BrowserPasteboard {
    var images = 0
    func writePageURL(_ url: URL) {}
    func writeText(_ text: String) {}
    func writeImage(_ image: NSImage, source: URL) { images += 1 }
}

/// A person who answers no sheet: the export gate's case shows none.
private final class SweepPasswordPerson: PageConfirmationPresenter, DeviceOwnerAuthenticating, PasswordSecretSurface {
    func confirm(_ confirmation: PageConfirmation, anchor: NSView?) async -> Bool { false }
    func authenticate(reason: String) async -> Bool { false }
    func reveal(_ secret: SecretBytes, site: String, username: String, anchor: NSView?) async {}
    func copy(_ secret: SecretBytes) {}
    func exportDestination(profileName: String, anchor: NSView?) async -> URL? { nil }
}
