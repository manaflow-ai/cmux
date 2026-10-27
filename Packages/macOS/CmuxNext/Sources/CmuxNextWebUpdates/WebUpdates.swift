import AppKit
import CmuxNextAgentPane
public import CmuxNextDesign
import CmuxNextPages
public import CmuxNextSettings
public import CmuxNextUpdater
public import CmuxNextWakeups
public import Foundation
import Observation

/// Web updates in the app (plans/cmux-next/web-ota.md). On a NIGHTLY bundle it names where each
/// bundled web output sits in an update, starts the launch check of the kept update before a
/// page loads, follows `updates.web`, and makes a ready update the served one at a safe point
/// (``WebSwapGate``, WebUpdates+SafePoint.swift): at once while no page shows, else once nobody has
/// touched cmux for a while (or it has been behind other apps for a moment) and every page answers
/// that a reload keeps what it holds, then reloads every page and agent pane in place. Until then
/// open pages keep the files they started with, so a page never mixes two builds' chunks.
/// The App reads the kept update from `main` (``startLaunchRead(bundle:on:)``), starts it with
/// ``prepare(_:launch:files:energy:shown:)``, calls ``follow(_:)`` with each `updates.*` read and
/// ``startChecks()`` once startup completes: no pointer is read from the network before that.
/// Observable, so the Settings card (``pageJSON``) follows the updater and the pending swap.
@Observable
public final class WebUpdates {
    public static let shared = WebUpdates()

    /// How the updater reads the network and keeps time: URLSession and the continuous clock in
    /// the app, a fake transport and a manual clock in tests.
    nonisolated struct Transport: Sendable {
        var fetch: WebUpdater.Fetch
        var download: WebUpdater.Download
        var clock: any Clock<Duration>

        static let network = Transport(fetch: { try await URLSession.shared.data(for: $0) },
                                       download: { try await WebUpdater.downloadToFile($0) }, clock: ContinuousClock())
    }

    /// The folder the pages' scheme handlers serve from and the views they served.
    @ObservationIgnored let overlay: WebBundleOverlay
    @ObservationIgnored let servedViews: WebBundleServedViews
    @ObservationIgnored private let transport: Transport

    public private(set) var updater: WebUpdater?
    /// The folder to serve from the next safe point (`.some(nil)`: the bundled web).
    public private(set) var pending: URL??
    /// The update the last swap served (`.some(nil)`: the bundled web), none before the first.
    private var swapped: WebUpdatePointer??
    /// The update ``pending`` swaps in.
    @ObservationIgnored private var pendingVersion: WebUpdatePointer?
    /// Pages waited for the launch check, so they serve its update until the first swap.
    @ObservationIgnored private var launchServed = false
    /// Whether the updater handed an update over; a late launch result never replaces it.
    @ObservationIgnored private var handedOver = false
    /// The next look for a safe point while an update is pending; it stops when none is.
    @ObservationIgnored let safePoint = DemandTimer(owner: "web-updates.safe-point")
    /// A look that is asking the pages (one at a time).
    @ObservationIgnored var looking = false
    /// What held the pending update at the last look (`updates.web.status` `waiting_for`).
    @ObservationIgnored var heldBy: String?
    /// When cmux last left the front (nil while it is there): the grace runs from it.
    @ObservationIgnored var resignedAt: ContinuousClock.Instant?
    /// Counts handoffs, so a look's page answers apply only to the update they were asked for.
    @ObservationIgnored var pendingGeneration = 0
    /// The note of a swap made while cmux was behind other apps, shown when it comes back.
    @ObservationIgnored var unseenNote: String?
    @ObservationIgnored private var observers: [Task<Void, Never>] = []
    @ObservationIgnored private var started = false
    /// The lanes the updater reads its trusted keys on (``WebUpdater/KeySource/bundled(_:)``), the
    /// app's Energy Saver policy and its shown windows (nil: checks whether or not one shows), from
    /// ``prepare(_:launch:files:energy:shown:)``; web updates start only once they are known.
    @ObservationIgnored private var inputs: (files: BackgroundWork, energy: EnergyPolicySource, shown: ShownWindows?)?
    @ObservationIgnored private var shownObservation: ShownWindowsObservation?
    /// The last `updates.*` followed, applied to the updater when it is made.
    @ObservationIgnored private var settings: UpdatesSettings?
    /// Whether startup completed (``startChecks()``): an updater made after it reads at once.
    @ObservationIgnored private var checksStarted = false

    init(overlay: WebBundleOverlay = .shared, servedViews: WebBundleServedViews = .shared, transport: Transport = .network) {
        self.overlay = overlay
        self.servedViews = servedViews
        self.transport = transport
    }

    /// What the launch read of the kept update found (``startLaunchRead(bundle:on:)``).
    public nonisolated struct Launch: Sendable {
        /// The web this app shipped with.
        let app: WebUpdater.App
        /// Where the updates are kept.
        let store: WebUpdateStore
        /// The kept update on disk, its tree checked against its signed digest.
        let kept: WebUpdater.Kept
    }

    /// NIGHTLY bundles and the tip app only (``WebUpdater/takesUpdates(_:)``).
    static func isAvailable(_ bundle: Bundle) -> Bool {
        WebUpdater.takesUpdates(UpdateBuildIdentity(infoDictionary: bundle.infoDictionary ?? [:]))
    }

    /// Starts the launch read of the kept update on `work`'s files lane: the bundled web's `abi`
    /// and build time, `state.json` and the kept tree's digest, read from `main` while AppKit
    /// starts, so neither the main thread nor the first page waits for the disk (p08-startup-077).
    /// Nil when this bundle takes no web updates.
    public static func startLaunchRead(bundle: Bundle = .main, on work: BackgroundWork) -> LaunchRead<Launch?>? {
        guard isAvailable(bundle), let pages = WebBundleOverlay.bundledPages,
              let store = WebUpdateStore.standard(bundleIdentifier: bundle.bundleIdentifier) else { return nil }
        let infoPlist = bundle.bundleURL.appending(path: "Contents/Info.plist")
        return LaunchRead(on: work, dropped: .some(nil)) {
            guard let app = WebUpdater.App.bundled(pages: pages, infoPlist: infoPlist) else { return nil }
            return Launch(app: app, store: store, kept: WebUpdater.readKept(store: store, app: app))
        }
    }

    /// Starts the launch check with the launch settings before any restored or prewarmed page can
    /// request its entry document: pages wait for `launch` (the read from ``startLaunchRead(bundle:on:)``,
    /// nil when this bundle takes no web updates), never the main thread. Applying the channel
    /// first keeps `updates.web: off` on the bundled web even while the settings observer is still
    /// starting. `files` is the app's blocking-work lanes (its one `BackgroundWork`). Checks wait
    /// `energy`'s poll stretch, with `shown` none is booked while no cmux window shows
    /// (p14-energy-032), and none reads the network before ``startChecks()``.
    public func prepare(_ settings: UpdatesSettings, launch: LaunchRead<Launch?>?, bundle: Bundle = .main,
                        files: BackgroundWork, energy: EnergyPolicySource, shown: ShownWindows?) {
        inputs = (files, energy, shown)
        self.settings = settings
        start(launch, bundle: bundle)
    }

    /// Startup completed: the updater reads the channel's pointer (at once while a window shows),
    /// then on its schedule.
    public func startChecks() {
        checksStarted = true
        updater?.startChecks()
    }

    /// Starts once. Before the first page loads, pages wait for the kept update's check; after,
    /// the kept update waits for a safe point. The updater is made when the launch read lands.
    private func start(_ launch: LaunchRead<Launch?>?, bundle: Bundle) {
        guard !started, inputs != nil, let launch else { return }
        started = true
        if let agentPane = AgentPaneView.bundledPage?.deletingLastPathComponent() {
            overlay.register(bundled: agentPane, output: WebUpdateTree.outputs[0])
        }
        if let resources = bundle.resourceURL {
            overlay.register(bundled: PageDescriptor.diffRoot(inAppResources: resources), output: WebUpdateTree.outputs[4])
        }
        if servedViews.isEmpty {
            launchServed = true
            overlay.load { [weak self] in await self?.launchTree(await launch.finished()) }
        } else {
            // A page already loaded bundled files: the kept update waits for a safe point.
            // task-owner: one launch check; it ends by itself
            Task { [weak self] in
                let tree = await self?.launchTree(await launch.finished())
                guard let self, let updater = self.updater, tree != nil, !handedOver else { return }
                ready(tree, version: updater.launchVersion)
            }
        }
        // task-owner: the app's activation events, for the life of the app
        observers.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didResignActiveNotification) {
                self?.resignedAt = .now
                self?.updater?.noteBackground()
                self?.scheduleSafePoint()
            }
        })
        // task-owner: the app's activation events, for the life of the app
        observers.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                self?.resignedAt = nil
                self?.updater?.noteActivation()
                self?.scheduleSafePoint()
                self?.showUnseenNote()
            }
        })
    }

    /// The launch check of the kept update the launch read found (nil: none, the bundled web), on
    /// the updater it makes then.
    private func launchTree(_ launch: Launch?) async -> URL? {
        guard let launch, let updater = updater ?? makeUpdater(launch) else { return nil }
        return await updater.launchTree()
    }

    /// Makes the updater from the launch read, with the last `updates.*` followed.
    private func makeUpdater(_ launch: Launch) -> WebUpdater? {
        guard let inputs else { return nil }
        let updater = WebUpdater(store: launch.store, app: launch.app, keys: .bundled(inputs.files), energy: inputs.energy,
                                 clock: transport.clock, kept: launch.kept, checksHeld: !checksStarted,
                                 fetch: transport.fetch, download: transport.download)
        updater.onReady = { [weak self] tree, pointer in
            self?.handedOver = true
            self?.ready(tree, version: pointer)
        }
        updater.served = { [overlay] in overlay.activeTree }
        // Checks come every minute only while cmux is in the front (the activation observers follow it).
        updater.foreground = NSApp?.isActive ?? false
        if let shown = inputs.shown {
            updater.noteShown(shown.anyShown)
            shownObservation = shown.observe { [weak updater] anyShown in updater?.noteShown(anyShown) }
        }
        self.updater = updater
        if let settings { follow(settings, updater: updater) }
        return updater
    }

    /// `updates.*`: the channel and what downloads may use (kept for the updater until the launch read made it).
    public func follow(_ settings: UpdatesSettings) {
        self.settings = settings
        guard let updater else { return }
        follow(settings, updater: updater)
    }

    private func follow(_ settings: UpdatesSettings, updater: WebUpdater) {
        updater.allowsConstrained = settings.meteredNetwork == .download
        updater.allowsExpensive = settings.meteredNetwork != .deferExpensive
        updater.follow(WebUpdater.Channel(rawValue: settings.web.rawValue) ?? .off)
    }

    /// The update the pages serve now (nil: the bundled web). The updater's `state.active` runs
    /// ahead of it while a swap waits for its safe point.
    public var served: WebUpdatePointer? {
        if let swapped { return swapped }
        return launchServed ? updater?.launchVersion : nil
    }

    /// The updater kept `tree`, `version`'s (both nil: serve the bundled web): swap it in at the
    /// next safe point.
    func ready(_ tree: URL?, version: WebUpdatePointer?) {
        pending = .some(tree)
        pendingVersion = version
        // A new handoff: what held the last one says nothing about it, and a look asking the
        // pages now asked about the last one (``look()`` checks the generation).
        pendingGeneration += 1
        heldBy = nil
        scheduleSafePoint()
    }

    /// Serves the pending folder now and reloads the pages; returns how many reloaded.
    @discardableResult
    public func applyPending() -> Int {
        guard let tree = pending else { return 0 }
        pending = nil
        heldBy = nil
        safePoint.cancel()
        let version = pendingVersion
        swapped = .some(version)
        guard overlay.activate(tree) else { return 0 }
        // task-owner: one prune of the trees nothing serves now; it ends by itself
        if let updater { Task { await updater.pruneUnused() } }
        let reloaded = servedViews.reloadServed()
        // A swap back to the bundled pages (no version) clears an unseen note of an earlier one.
        if reloaded > 0 { unseenNote = nil }
        if reloaded > 0, let version { note(version.updatedNote) }
        return reloaded
    }

    /// A quiet "Updated to <commit>" toast that dismisses itself (CmuxToastCenter), in the front
    /// window now, or once cmux comes back to the front.
    private func note(_ message: String) {
        unseenNote = message
        showUnseenNote()
    }

    private func showUnseenNote() {
        guard let message = unseenNote, NSApp.isActive, let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        unseenNote = nil
        _ = CmuxToastCenter.shared.show(CmuxToast(id: "web-update", message: message, duration: .seconds(4)), in: window)
    }
}
