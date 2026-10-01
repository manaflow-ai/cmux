import AppKit
import CmuxSettings
import CmuxUpdater
import CmuxUpdaterUI
import Observation
import SwiftUI

/// Owns What's New: the launch check, the quiet indicator, and the recap
/// window. Every entrypoint (Help menu, command palette, sidebar help menu,
/// the launch check) goes through ``presentOnDemand(source:)`` or the launch
/// path here, so they share one presentation and one "seen" record.
///
/// Content comes from `cmux.com/api/changelog/highlights`, the same entries
/// the website changelog renders. The `app.whatsNew` setting picks how much
/// happens on its own after an update:
/// - off: nothing;
/// - quiet (default): a dot on the sidebar help button until the recap is
///   opened; it never opens anything or takes focus;
/// - sheet: the recap opens once after the first launch of a new version,
///   as a sheet on a main terminal window; with no such window it falls back
///   to the quiet indicator rather than opening a window of its own.
///
/// The launch check runs once, when AppDelegate reports that startup session
/// restore has settled (``startupSessionRestoreDidSettle()``), so the restored
/// main windows exist before anything decides where the recap attaches.
@MainActor
@Observable
final class WhatsNewCenter {
    static let shared = WhatsNewCenter()

    /// The release key (see ``WhatsNewAutomaticPresentation/releaseKey(_:)``)
    /// last shown to, or opened by, the user.
    static let lastSeenReleaseDefaultsKey = "cmux.whatsNew.lastSeenRelease"

    /// Highlights for this version are waiting and the user has not opened
    /// them. Drives the quiet indicator only.
    private(set) var hasUnseenHighlights = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let loader: @Sendable () async throws -> WhatsNewCatalog
    @ObservationIgnored private let buildFlavor: BuildFlavor
    @ObservationIgnored private let versionOverride: String?
    @ObservationIgnored private var catalog: WhatsNewCatalog?
    @ObservationIgnored private var pendingReleases: [WhatsNewRelease] = []
    /// The one launch check; non-nil once startup restore has settled.
    @ObservationIgnored private var launchTask: Task<Void, Never>?
    /// The catalog load filling the open recap; cancelled when the recap
    /// closes or shows other content.
    @ObservationIgnored private var fillTask: Task<Void, Never>?
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var viewModel: WhatsNewViewModel?
    @ObservationIgnored private var windowCloseObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var modeObserver: (any NSObjectProtocol)?
    /// Whether this launch is a new user's first run: a Mac that never showed
    /// the welcome is a new install, not an update. Captured when the center
    /// is created, which `cmuxApp.init` does before the first workspace marks
    /// the welcome as shown.
    @ObservationIgnored private let launchIsFirstRun: Bool

    init(
        defaults: UserDefaults = .standard,
        loader: @escaping @Sendable () async throws -> WhatsNewCatalog = { try await WhatsNewCatalogLoader().load() },
        buildFlavor: BuildFlavor = .current,
        currentVersion: String? = nil
    ) {
        self.defaults = defaults
        self.loader = loader
        self.buildFlavor = buildFlavor
        versionOverride = currentVersion
        launchIsFirstRun = !defaults.bool(forKey: AccountCatalogSection().welcomeShown.userDefaultsKey)
    }

    private var currentVersion: String {
        versionOverride ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
    }

    private var mode: WhatsNewPresentationMode {
        UserDefaultsSettingsClient(defaults: defaults).value(for: AppCatalogSection().whatsNew)
    }

    // MARK: - Launch

    /// Runs the launch check the first time startup session restore settles:
    /// the snapshot was applied (every restored window created), or there was
    /// nothing to restore. Later calls, such as a manual session reopen, do
    /// nothing.
    func startupSessionRestoreDidSettle() {
        guard launchTask == nil else { return }
        // Switching to Off anywhere (Settings, cmux.json) clears the dot.
        modeObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.hasUnseenHighlights, self.mode == .off else { return }
                self.hasUnseenHighlights = false
            }
        }
        launchTask = Task { @MainActor [weak self] in
            await self?.runLaunchCheck()
        }
    }

    /// Waits for the one launch check to finish, including its catalog load.
    func waitForLaunchCheck() async {
        await launchTask?.value
    }

    /// Decides what this launch announces, loads the catalog when it needs
    /// to, and then shows the sheet or the quiet indicator.
    private func runLaunchCheck() async {
        let decision = WhatsNewAutomaticPresentation().decide(
            mode: mode,
            flavor: buildFlavor,
            currentVersion: currentVersion,
            lastSeenVersion: defaults.string(forKey: Self.lastSeenReleaseDefaultsKey),
            isFirstRun: launchIsFirstRun
        )
        let since: String?
        let decidedToPresent: Bool
        switch decision {
        case .none:
            return
        case .recordCurrent:
            markSeen()
            return
        case .indicate(let lastSeen):
            since = lastSeen
            decidedToPresent = false
        case .present(let lastSeen):
            since = lastSeen
            decidedToPresent = true
        }
        guard let current = WhatsNewAutomaticPresentation.releaseKey(currentVersion),
              let catalog = try? await loadCatalog() else {
            // Offline or no parseable version: try again next launch.
            return
        }
        let releases = catalog.releasesToAnnounce(after: since, through: current)
        // No highlights published for this version (yet): leave the record
        // alone so a later launch can still announce them.
        guard !releases.isEmpty else { return }
        // The setting and the seen record may both have changed while the
        // catalog was loading, so resolve the launch against how they read
        // now rather than against the pre-load decision alone.
        let outcome = WhatsNewAutomaticPresentation.launchOutcome(
            decidedToPresent: decidedToPresent,
            liveMode: mode,
            announcedVersion: since,
            liveAnnouncedVersion: defaults
                .string(forKey: Self.lastSeenReleaseDefaultsKey)
                .flatMap(WhatsNewAutomaticPresentation.releaseKey)
        )
        switch outcome {
        case .suppress:
            return
        case .indicate:
            pendingReleases = releases
            hasUnseenHighlights = true
        case .presentSheet:
            pendingReleases = releases
            // The launch recap only ever attaches to a main terminal window
            // and never activates cmux. With no window to attach to (all
            // closed or minimized by the time the catalog arrives), keep the
            // dot instead.
            if let parent = sheetParentCandidate() {
                present(releases: releases, source: "launch", sheetParent: parent)
            } else {
                hasUnseenHighlights = true
            }
        }
    }

    // MARK: - On demand

    /// Opens the recap. Used by the Help menu, the command palette, and the
    /// sidebar help menu.
    func presentOnDemand(source: String) {
        if !pendingReleases.isEmpty {
            present(releases: pendingReleases, source: source)
            return
        }
        startFill(showWindow(phase: .loading, activates: true))
    }

    /// Loads the recent releases into `model`, replacing any load in flight.
    ///
    /// Marking seen happens here, on a load that produced something to read,
    /// not when the window opens. A recap that failed to load, or that had no
    /// highlights to show, must not consume the one automatic announcement
    /// for this version.
    private func startFill(_ model: WhatsNewViewModel) {
        fillTask?.cancel()
        model.phase = .loading
        fillTask = Task { @MainActor [weak self, weak model] in
            let catalog = try? await self?.loadCatalog()
            guard !Task.isCancelled, let self, let model else { return }
            guard let catalog else {
                model.phase = .failed
                return
            }
            // A build without a parseable version shows the newest releases.
            let current = WhatsNewAutomaticPresentation.releaseKey(self.currentVersion) ?? "\(Int.max)"
            let releases = catalog.recentReleases(through: current)
            model.phase = .loaded(releases)
            if !releases.isEmpty {
                self.markSeen()
            }
        }
    }

    /// Shows `releases` in the recap and records them as seen.
    private func present(releases: [WhatsNewRelease], source: String, sheetParent: NSWindow? = nil) {
        fillTask?.cancel()
        fillTask = nil
        // The launch path never steals focus from another app.
        _ = showWindow(phase: .loaded(releases), activates: source != "launch", sheetParent: sheetParent)
        markSeen()
#if DEBUG
        cmuxDebugLog("whatsNew.present source=\(source) releases=\(releases.map(\.version).joined(separator: ","))")
#endif
    }

    /// Records the running version as seen and clears the quiet indicator.
    private func markSeen() {
        if let key = WhatsNewAutomaticPresentation.releaseKey(currentVersion) {
            defaults.set(key, forKey: Self.lastSeenReleaseDefaultsKey)
        }
        hasUnseenHighlights = false
        // The launch set has been shown. Later opens ask the catalog again so
        // they reflect a retry or a catalog that has since been published.
        pendingReleases = []
    }

    /// The catalog, fetched once per process and then reused.
    private func loadCatalog() async throws -> WhatsNewCatalog {
        if let catalog { return catalog }
        let loaded: WhatsNewCatalog
        if let injected = Self.catalogForUITest() {
            loaded = injected
        } else {
            loaded = try await loader()
        }
        catalog = loaded
        return loaded
    }

    /// A catalog handed in by a UI test instead of the network, so a screenshot
    /// tour can show the recap with content of its own choosing and never
    /// depends on the website being reachable. Same shape as the endpoint's
    /// body, and the media host rule still applies to whatever it contains.
    private static func catalogForUITest() -> WhatsNewCatalog? {
        let raw = ProcessInfo.processInfo.environment["CMUX_UI_TEST_WHATS_NEW_CATALOG_JSON"]
            ?? UserDefaults.standard.string(forKey: "CMUX_UI_TEST_WHATS_NEW_CATALOG_JSON")
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        return try? WhatsNewCatalog.decode(data)
    }

    // MARK: - Window

    private static var modeOptions: [WhatsNewModeOption] {
        WhatsNewPresentationMode.allCases.map { mode in
            WhatsNewModeOption(id: mode.rawValue, title: WhatsNewCenter.title(for: mode))
        }
    }

    /// The label for one `app.whatsNew` choice, shared with Settings.
    static func title(for mode: WhatsNewPresentationMode) -> String {
        switch mode {
        case .off:
            return String(localized: "settings.app.whatsNew.off", defaultValue: "Off")
        case .quiet:
            return String(localized: "settings.app.whatsNew.quiet", defaultValue: "Quiet")
        case .sheet:
            return String(localized: "settings.app.whatsNew.sheet", defaultValue: "Show Once")
        }
    }

    /// Shows the recap, reusing an open one. It opens as a sheet on
    /// `sheetParent`, else on the frontmost main window, or as a standalone
    /// window when there is none. Only an activating call brings it forward.
    private func showWindow(
        phase: WhatsNewViewModel.Phase,
        activates: Bool,
        sheetParent: NSWindow? = nil
    ) -> WhatsNewViewModel {
        // A sheet whose parent closed never ran its completion; drop it.
        if let window, window.sheetParent == nil, !window.isVisible {
            forgetWindow()
        }
        if let window, let viewModel {
            viewModel.phase = phase
            viewModel.selectedModeID = mode.rawValue
            if activates {
                NSApp.activate(ignoringOtherApps: true)
                (window.sheetParent ?? window).makeKeyAndOrderFront(nil)
            }
            return viewModel
        }

        let model = WhatsNewViewModel(phase: phase, selectedModeID: mode.rawValue)
        let actions = WhatsNewViewActions(
            openURL: { url in NSWorkspace.shared.open(url) },
            retry: { [weak self, weak model] in
                guard let self, let model else { return }
                self.startFill(model)
            },
            selectMode: { [weak self] rawValue in
                guard let self, let selected = WhatsNewPresentationMode(rawValue: rawValue) else { return }
                UserDefaultsSettingsClient(defaults: self.defaults).set(selected, for: AppCatalogSection().whatsNew)
                if selected == .off { self.hasUnseenHighlights = false }
            },
            done: { [weak self] in self?.closeWindow() }
        )
        let root = WhatsNewView(model: model, modeOptions: Self.modeOptions, actions: actions)
            .onExitCommand { [weak self] in self?.closeWindow() }
        let hosting = NSHostingController(rootView: root)
        let newWindow = NSWindow(contentViewController: hosting)
        newWindow.styleMask = [.titled, .closable]
        newWindow.title = String(localized: "whatsNew.title", defaultValue: "What's New in cmux")
        newWindow.isReleasedWhenClosed = false
        newWindow.identifier = NSUserInterfaceItemIdentifier("cmux.whatsNew")
        window = newWindow
        viewModel = model

        if let parent = sheetParent ?? sheetParentCandidate() {
            parent.beginSheet(newWindow) { [weak self] _ in
                self?.forgetWindow()
            }
            // The parent is the frontmost main terminal window, which is not
            // necessarily the frontmost window: Settings or About can be over
            // it. Without this the sheet opens behind them and the Help menu
            // looks like it did nothing.
            if activates {
                NSApp.activate(ignoringOtherApps: true)
                parent.makeKeyAndOrderFront(nil)
            }
        } else {
            windowCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: newWindow,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.forgetWindow() }
            }
            newWindow.center()
            if activates {
                NSApp.activate(ignoringOtherApps: true)
                newWindow.makeKeyAndOrderFront(nil)
            } else {
                newWindow.orderFront(nil)
            }
        }
        return model
    }

    /// The frontmost visible main terminal window without a sheet. Works
    /// while cmux is inactive, when there is no key or main window.
    private func sheetParentCandidate() -> NSWindow? {
        guard let appDelegate = AppDelegate.shared else { return nil }
        let ordered = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 } + NSApp.orderedWindows
        return ordered.first { candidate in
            candidate.isVisible
                && !candidate.isMiniaturized
                && candidate.attachedSheet == nil
                && appDelegate.isMainTerminalWindow(candidate)
        }
    }

    /// Dismisses the recap, whether it is a sheet or a standalone window.
    private func closeWindow() {
        guard let window else { return }
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.close()
        }
        forgetWindow()
    }

    /// Drops the recap window, its model, and any load still filling it.
    private func forgetWindow() {
        fillTask?.cancel()
        fillTask = nil
        if let windowCloseObserver {
            NotificationCenter.default.removeObserver(windowCloseObserver)
        }
        windowCloseObserver = nil
        window = nil
        viewModel = nil
    }
}
