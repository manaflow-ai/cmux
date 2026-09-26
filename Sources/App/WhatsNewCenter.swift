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
/// - sheet: the recap opens once after the first launch of a new version.
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
    @ObservationIgnored private let loader: WhatsNewCatalogLoader
    @ObservationIgnored private var catalog: WhatsNewCatalog?
    @ObservationIgnored private var pendingReleases: [WhatsNewRelease] = []
    @ObservationIgnored private var launchCheckScheduled = false
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var viewModel: WhatsNewViewModel?
    @ObservationIgnored private var windowCloseObserver: (any NSObjectProtocol)?

    init(defaults: UserDefaults = .standard, loader: WhatsNewCatalogLoader = WhatsNewCatalogLoader()) {
        self.defaults = defaults
        self.loader = loader
    }

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    private var mode: WhatsNewPresentationMode {
        UserDefaultsSettingsClient(defaults: defaults).value(for: AppCatalogSection().whatsNew)
    }

    // MARK: - Launch

    /// Runs the launch check once, a few seconds after launch so it never
    /// competes with window restore.
    func scheduleLaunchCheck() {
        guard !launchCheckScheduled else { return }
        launchCheckScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await self?.runLaunchCheck()
        }
    }

    private func runLaunchCheck() async {
        let decision = WhatsNewAutomaticPresentation().decide(
            mode: mode,
            flavor: BuildFlavor.current,
            currentVersion: currentVersion,
            lastSeenVersion: defaults.string(forKey: Self.lastSeenReleaseDefaultsKey)
        )
        let since: String?
        let presents: Bool
        switch decision {
        case .none:
            return
        case .indicate(let lastSeen):
            since = lastSeen
            presents = false
        case .present(let lastSeen):
            since = lastSeen
            presents = true
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
        pendingReleases = releases
        if presents {
            present(releases: releases, source: "launch")
        } else {
            hasUnseenHighlights = true
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
        let model = showWindow(phase: .loading, activates: true)
        markSeen()
        Task { @MainActor [weak self] in
            await self?.fill(model)
        }
    }

    private func fill(_ model: WhatsNewViewModel) async {
        model.phase = .loading
        guard let catalog = try? await loadCatalog() else {
            model.phase = .failed
            return
        }
        // A build without a parseable version shows the newest releases.
        let current = WhatsNewAutomaticPresentation.releaseKey(currentVersion) ?? "\(Int.max)"
        model.phase = .loaded(catalog.recentReleases(through: current))
    }

    private func present(releases: [WhatsNewRelease], source: String) {
        // The launch path never steals focus from another app.
        _ = showWindow(phase: .loaded(releases), activates: source != "launch")
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
    }

    private func loadCatalog() async throws -> WhatsNewCatalog {
        if let catalog { return catalog }
        let loaded = try await loader.load()
        catalog = loaded
        return loaded
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

    /// Shows the recap, reusing an open one. It opens as a sheet on the
    /// frontmost main window, or as a standalone window when there is none.
    private func showWindow(phase: WhatsNewViewModel.Phase, activates: Bool) -> WhatsNewViewModel {
        if let window, let viewModel {
            viewModel.phase = phase
            viewModel.selectedModeID = mode.rawValue
            (window.sheetParent ?? window).makeKeyAndOrderFront(nil)
            return viewModel
        }

        let model = WhatsNewViewModel(phase: phase, selectedModeID: mode.rawValue)
        let actions = WhatsNewViewActions(
            openURL: { url in NSWorkspace.shared.open(url) },
            retry: { [weak self, weak model] in
                guard let self, let model else { return }
                Task { @MainActor in await self.fill(model) }
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

        if let parent = sheetParentCandidate() {
            parent.beginSheet(newWindow) { [weak self] _ in
                self?.forgetWindow()
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

    private func sheetParentCandidate() -> NSWindow? {
        let candidates = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }
        return candidates.first { candidate in
            candidate.isVisible
                && candidate.attachedSheet == nil
                && candidate.sheetParent == nil
                && !(candidate is NSPanel)
                && candidate.styleMask.contains(.titled)
        }
    }

    private func closeWindow() {
        guard let window else { return }
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.close()
        }
        forgetWindow()
    }

    private func forgetWindow() {
        if let windowCloseObserver {
            NotificationCenter.default.removeObserver(windowCloseObserver)
        }
        windowCloseObserver = nil
        window = nil
        viewModel = nil
    }
}
