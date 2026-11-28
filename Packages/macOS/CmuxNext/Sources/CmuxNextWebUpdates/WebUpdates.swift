import AppKit
import CmuxNextAgentPane
public import CmuxNextDaemon
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
    /// Runs the app's bundled `cmux` CLI with the words given and returns its standard output (nil
    /// when it could not run): the App sets it, for `cmux app web-pieces check` (WebUpdates+Pieces.swift).
    @ObservationIgnored public var piecesCLI: (@Sendable ([String]) async -> Data?)?
    /// The app's bundled `cmux`, which fetches a web update by `cas/1` while `updates.webCas` is on
    /// (WebUpdates+Cas.swift).
    @ObservationIgnored var bundledCLI: BundledExecutable?
    /// The last answer of `cmux app web-pieces check`: what each web piece is served from.
    var pieces: WebPiecesAnswer?
    /// The read of the switch file that runs now; the next one waits for it.
    @ObservationIgnored var piecesRead: Task<Void, Never>?
    /// Reads the channel's drill switch file instead (`updates.web.pieces.check` with `drill`), until
    /// cmux quits: a switch is rehearsed on this Mac before every app takes it.
    @ObservationIgnored var piecesDrill = false
    /// The kept updates' folders that verified in this run, so a pieces read does not hash them
    /// again after every check (``resolve(_:_:_:verified:)``).
    @ObservationIgnored var verifiedTrees = VerifiedTrees()
    @ObservationIgnored private var observers: [Task<Void, Never>] = []
    @ObservationIgnored private var started = false

    /// NIGHTLY bundles and the tip app only (``WebUpdater/takesUpdates(_:)``).
    static func isAvailable(_ bundle: Bundle) -> Bool {
        WebUpdater.takesUpdates(UpdateBuildIdentity(infoDictionary: bundle.infoDictionary ?? [:]))
    }

    /// Starts the launch check with the launch settings before any restored or prewarmed page can
    /// request its entry document. Applying the channel first keeps `updates.web: off` on the
    /// bundled web even while the settings observer is still starting.
    /// `cli`: the app's bundled `cmux`, which reads the switch file of web pieces
    /// (WebUpdates+Pieces.swift); without it no piece is switched out.
    public func prepare(_ settings: UpdatesSettings, bundle: Bundle = .main, cli: BundledExecutable? = nil) {
        if let cli {
            bundledCLI = cli
            piecesCLI = { words in
                guard let url = await cli.resolve(),
                      let ran = await BundledCLIRun.run(url, words, timeout: .seconds(20)), ran.status == 0 else { return nil }
                return ran.stdout
            }
        }
        start(bundle: bundle, settings: settings)
    }

    /// Names where each bundled web folder outside the pages folder sits inside an update
    /// (``WebUpdateTree/outputs``), so its requests read the active update: the agent pane, Agent
    /// Activity (the root the app registered for its page id at launch, before this runs) and the
    /// viewers (`appResources`: the app's resources folder).
    static func registerBundledFolders(_ overlay: WebBundleOverlay, appResources: URL?) {
        if let agentPane = AgentPaneView.bundledPage?.deletingLastPathComponent() {
            overlay.register(bundled: agentPane, output: WebUpdateTree.agentPaneOutput)
        }
        if let activity = PageID.bundledRoot(for: "cmux.agent-activity") {
            overlay.register(bundled: activity, output: WebUpdateTree.agentActivityOutput)
        }
        if let appResources {
            overlay.register(bundled: PageDescriptor.diffRoot(inAppResources: appResources), output: WebUpdateTree.webviewsAppOutput)
        }
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
        Self.registerBundledFolders(overlay, appResources: bundle.resourceURL)
        let updater = WebUpdater(store: store, app: app)
        updater.onReady = { [weak self] tree, pointer in
            self?.handedOver = true
            self?.ready(tree, version: pointer)
        }
        updater.served = {
            let overlay = WebBundleOverlay.shared
            return Array(Set(WebBundleServedViews.shared.pinnedTrees + overlay.switchedTrees + [overlay.activeTree].compactMap { $0 }))
        }
        updater.onChecked = { [weak self] in self?.readPieces(offline: false) }
        updater.refuses = { [weak self, weak updater] pointer in
            guard let self, let updater else { return false }
            return await piecesRefuse(pointer, updater)
        }
        // Checks come every minute only while cmux is in the front (the activation observers follow it).
        updater.foreground = NSApp?.isActive ?? false
        self.updater = updater
        if let settings { follow(settings, updater: updater) }
        if WebBundleServedViews.shared.isEmpty {
            launchServed = true
            // The pieces switched out when cmux last ran stay out from the first page on.
            overlay.load { [weak self] in
                let tree = await updater.launchTree()
                let refused = await self?.restorePieces(updater) ?? false
                return refused ? nil : tree
            }
        } else {
            // A page already loaded bundled files: the kept update waits for a safe point.
            // task-owner: one launch check; it ends by itself
            Task { [weak self] in
                let tree = await updater.launchTree()
                self?.readPieces(offline: true)
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
        // RFD 0166: off by default; on, a miss of any kind takes the archive in the same check.
        updater.casFetch = settings.webCas ? casFetcher() : nil
        updater.follow(WebUpdater.Channel(rawValue: settings.webInEffect.rawValue) ?? .off)
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

    /// What a page that loads `tree` (nil: the bundled web) is served now: `tree`, less the pieces
    /// the channel's switch file switched out.
    func target(_ tree: URL?) -> WebBundleOverlay.Serving {
        WebBundleOverlay.shared.serving(tree: tree)
    }

    /// The switch file moved a piece to another folder (WebUpdates+Pieces.swift): each open page
    /// that reads that piece reloads at its own safe point, as for an update.
    func switchesChanged() async {
        let tree = await WebBundleOverlay.shared.current()
        if pending == nil { pending = .some(tree) }
        pendingSince = .now
        pendingGeneration += 1
        heldBy = nil
        scheduleSafePoint()
    }

    /// Reloads every open page still on an older update now, whatever holds it (`updates.web.apply`,
    /// for tests and support); returns how many reloaded.
    @discardableResult
    public func applyPending() -> Int {
        guard let tree = pending else { return 0 }
        let target = target(tree)
        let behind = WebBundleServedViews.shared.behind(target)
        finishPending()
        // A swap shows nothing (Leo, 2026-10-30: "i dont think i need to see this"); Settings'
        // Web UI card shows the served version.
        return WebBundleServedViews.shared.reload(behind, to: target)
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
