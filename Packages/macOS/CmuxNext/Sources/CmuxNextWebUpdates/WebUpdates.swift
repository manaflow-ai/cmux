import AppKit
import CmuxNextAgentPane
import CmuxNextPages
public import CmuxNextSettings
public import CmuxNextUpdater
import CmuxNextWakeups
public import Foundation
import Observation

/// Web updates in the app (plans/cmux-next/web-ota.md). On a NIGHTLY bundle it names where each
/// bundled web output sits in an update, starts the launch check of the kept update before a
/// page loads, follows `updates.web`, and serves a ready update to every page that loads after it,
/// then reloads each open page and agent pane in place at its own safe point (``WebSwapGate``,
/// WebUpdates+SafePoint.swift): once it answers that a reload keeps what it holds and, for the page
/// being typed into, once input went quiet. Until then an open page keeps reading the files it
/// started with (``WebBundleServedViews``), so a page never mixes two builds' chunks, and one busy
/// page never holds the others.
/// The App calls ``follow(_:bundle:)`` with each `updates.*` read; the first call starts it.
/// Observable, so the Settings card (``pageJSON``) follows the updater and the pending swap.
@Observable
public final class WebUpdates {
    public static let shared = WebUpdates()

    public private(set) var updater: WebUpdater?
    /// The folder open pages reload into at their safe points while any still reads an older one
    /// (`.some(nil)`: the bundled web).
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
    /// When ``pending`` was handed over: past ``WebSwapGate/inputCap`` the page being typed into
    /// needs only a short quiet.
    @ObservationIgnored var pendingSince: ContinuousClock.Instant?
    @ObservationIgnored private var observers: [Task<Void, Never>] = []
    @ObservationIgnored private var started = false

    /// NIGHTLY bundles and the tip app only (``WebUpdater/takesUpdates(_:)``).
    static func isAvailable(_ bundle: Bundle) -> Bool {
        WebUpdater.takesUpdates(UpdateBuildIdentity(infoDictionary: bundle.infoDictionary ?? [:]))
    }

    /// Starts the launch check with the launch settings before any restored or prewarmed page can
    /// request its entry document. Applying the channel first keeps `updates.web: off` on the
    /// bundled web even while the settings observer is still starting.
    public func prepare(_ settings: UpdatesSettings, bundle: Bundle = .main) {
        start(bundle: bundle, settings: settings)
    }

    /// Starts once. Before the first page loads, pages wait for the kept update's check; after,
    /// the kept update waits for a safe point.
    private func start(bundle: Bundle, settings: UpdatesSettings? = nil) {
        guard !started else { return }
        started = true
        guard Self.isAvailable(bundle),
              let pages = WebBundleOverlay.bundledPages,
              let app = WebUpdater.App.bundled(pages: pages, infoPlist: bundle.bundleURL.appending(path: "Contents/Info.plist")),
              let store = WebUpdateStore.standard(bundleIdentifier: bundle.bundleIdentifier)
        else { return }
        let overlay = WebBundleOverlay.shared
        if let agentPane = AgentPaneView.bundledPage?.deletingLastPathComponent() {
            overlay.register(bundled: agentPane, output: WebUpdateTree.outputs[0])
        }
        if let resources = bundle.resourceURL {
            overlay.register(bundled: PageDescriptor.diffRoot(inAppResources: resources), output: WebUpdateTree.outputs[4])
        }
        let updater = WebUpdater(store: store, app: app)
        updater.onReady = { [weak self] tree, pointer in
            self?.handedOver = true
            self?.ready(tree, version: pointer)
        }
        updater.served = { Array(Set(WebBundleServedViews.shared.pinnedTrees + [WebBundleOverlay.shared.activeTree].compactMap { $0 })) }
        // Checks come every minute only while cmux is in the front (the activation observers follow it).
        updater.foreground = NSApp?.isActive ?? false
        self.updater = updater
        if let settings { follow(settings, updater: updater) }
        if WebBundleServedViews.shared.isEmpty {
            launchServed = true
            overlay.load { await updater.launchTree() }
        } else {
            // A page already loaded bundled files: the kept update waits for a safe point.
            // task-owner: one launch check; it ends by itself
            Task { [weak self] in
                let tree = await updater.launchTree()
                guard let self, tree != nil, !handedOver else { return }
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
            }
        })
    }

    /// `updates.*`: the channel and what downloads may use. The first call starts web updates.
    public func follow(_ settings: UpdatesSettings, bundle: Bundle = .main) {
        start(bundle: bundle)
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

    /// The updater kept `tree`, `version`'s (both nil: serve the bundled web): pages that load
    /// from now on get it, and each open page reloads into it at its own safe point.
    func ready(_ tree: URL?, version: WebUpdatePointer?) {
        pending = .some(tree)
        pendingVersion = version
        pendingSince = .now
        // A new handoff: what held the last one says nothing about it, and a look asking the
        // pages now asked about the last one (``look()`` checks the generation).
        pendingGeneration += 1
        heldBy = nil
        swapped = .some(version)
        WebBundleOverlay.shared.activate(tree)
        scheduleSafePoint()
    }

    /// Reloads every open page still on an older update now, whatever holds it (`updates.web.apply`,
    /// for tests and support); returns how many reloaded.
    @discardableResult
    public func applyPending() -> Int {
        guard let tree = pending else { return 0 }
        let behind = WebBundleServedViews.shared.behind(tree)
        finishPending()
        // A swap shows nothing (Leo, 2026-10-30: "i dont think i need to see this"); Settings'
        // Web UI card shows the served version.
        return WebBundleServedViews.shared.reload(behind, to: tree)
    }

    /// Every open page reads the pending update: nothing is pending any more, and the trees no
    /// page reads go.
    func finishPending() {
        pending = nil
        pendingSince = nil
        heldBy = nil
        safePoint.cancel()
        // task-owner: one prune of the trees nothing serves now; it ends by itself
        if let updater { Task { await updater.pruneUnused() } }
    }
}
