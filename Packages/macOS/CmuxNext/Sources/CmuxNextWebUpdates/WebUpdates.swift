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
/// page loads, follows `updates.web`, and makes a ready update the served one at a safe point
/// (``WebSwapGate``, WebUpdates+SafePoint.swift): at once while no page shows, else once nobody has
/// touched cmux for a while (or it has been behind other apps for a moment) and every page answers
/// that a reload keeps what it holds, then reloads every page and agent pane in place. Until then
/// open pages keep the files they started with, so a page never mixes two builds' chunks.
/// The App calls ``follow(_:bundle:)`` with each `updates.*` read; the first call starts it.
/// Observable, so the Settings card (``pageJSON``) follows the updater and the pending swap.
@Observable
public final class WebUpdates {
    public static let shared = WebUpdates()

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
        updater.served = { WebBundleOverlay.shared.activeTree }
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
        guard WebBundleOverlay.shared.activate(tree) else { return 0 }
        // task-owner: one prune of the trees nothing serves now; it ends by itself
        if let updater { Task { await updater.pruneUnused() } }
        // A swap shows nothing (Leo, 2026-10-30: "i dont think i need to see this"); Settings'
        // Web UI card shows the served version.
        return WebBundleServedViews.shared.reloadServed()
    }
}
