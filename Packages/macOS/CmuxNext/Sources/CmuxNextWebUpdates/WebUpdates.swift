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
/// page loads, follows `updates.web`, and makes a ready update the served one at a safe point:
/// at once while no page shows, else once cmux has been in the background for a moment (nobody is
/// typing; a composer draft survives the reload in its origin's storage), then reloads every page
/// and agent pane in place. Until then
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
    /// The wait in the background before an update swaps in.
    @ObservationIgnored private let safePoint = DemandTimer(owner: "web-updates.safe-point")
    @ObservationIgnored private var observers: [Task<Void, Never>] = []
    @ObservationIgnored private var started = false
    /// How long cmux stays in the background before an update swaps in.
    let grace: Duration = .seconds(3)

    /// NIGHTLY bundles only (`com.cmuxterm.app.nightly[.<tag>]`): Debug builds keep a developer's
    /// own web, and Release and RC builds the web they were built with.
    static func isAvailable(bundleID: String?) -> Bool {
        guard let bundle = bundleID else { return false }
        return bundle == "com.cmuxterm.app.nightly" || bundle.hasPrefix("com.cmuxterm.app.nightly.")
    }

    /// Starts once. Before the first page loads, pages wait for the kept update's check; after,
    /// the kept update waits for a safe point.
    func start(bundle: Bundle) {
        guard !started else { return }
        started = true
        guard Self.isAvailable(bundleID: bundle.bundleIdentifier),
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
        self.updater = updater
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
                self?.scheduleSafePoint()
            }
        })
        // task-owner: the app's activation events, for the life of the app
        observers.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                self?.safePoint.cancel()
                self?.updater?.noteActivation()
            }
        })
    }

    /// `updates.*`: the channel and what downloads may use. The first call starts web updates.
    public func follow(_ settings: UpdatesSettings, bundle: Bundle = .main) {
        start(bundle: bundle)
        guard let updater else { return }
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
        if WebBundleServedViews.shared.isEmpty || !NSApp.isActive { scheduleSafePoint() }
    }

    /// Serves the pending folder now and reloads the pages; returns how many reloaded.
    @discardableResult
    public func applyPending() -> Int {
        guard let tree = pending else { return 0 }
        pending = nil
        swapped = .some(pendingVersion)
        guard WebBundleOverlay.shared.activate(tree) else { return 0 }
        // task-owner: one prune of the trees nothing serves now; it ends by itself
        if let updater { Task { await updater.pruneUnused() } }
        return WebBundleServedViews.shared.reloadServed()
    }

    /// Swaps the pending update in after ``grace`` (at once while no page shows); cmux coming
    /// back to the front cancels the wait.
    private func scheduleSafePoint() {
        guard pending != nil else { return }
        let wait = WebBundleServedViews.shared.isEmpty ? Duration.zero : grace
        safePoint.scheduleIfIdle(after: wait) { @MainActor [weak self] in self?.applyPending() }
    }
}
