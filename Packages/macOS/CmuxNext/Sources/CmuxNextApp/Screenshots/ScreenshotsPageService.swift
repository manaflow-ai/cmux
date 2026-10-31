import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextFileGrid
import CmuxNextFiles
import CmuxNextScreenshots
import CmuxNextSettings
import Foundation
import Observation

/// Opens `cmux://screenshots` and makes its pages. Every page shares one
/// thumbnail cache and follows the `screenshots.*` settings: a change finds
/// the folders again (off the main actor) and updates each open page.
@MainActor
final class ScreenshotsPageService {
    private weak var services: AppServices?
    /// One cache for every Screenshots page (and, later, the Finder pane's grids).
    let thumbnails = ThumbnailCache()
    private let workspace = AppScreenshotsWorkspace()
    /// Drops, renames and trashes go through the Files pane's operations.
    private let files = FileOperator()
    private let detector = ScreenshotSourceDetector(environment: SystemScreenshotEnvironment())
    /// Open pages by tab key.
    private var pages: [String: ScreenshotsPageTab] = [:]
    /// The last folders found, and the settings they were found for.
    private var detected: (settings: ScreenshotsSettings, sources: [ScreenshotSource])?
    private var detection: Task<Void, Never>?
    private var followsSettings = false

    init(services: AppServices) {
        self.services = services
    }

    /// Selects or opens the Screenshots tab, in front only for the person's own run; any other is told (``ScreenshotsOpen``).
    func open(_ invocation: ActionInvocation) -> ActionEffect {
        let run = ScreenshotsOpen(personsRun: invocation.isPersonsOwnRun)
        guard let window = services?.windows.active else { return .refused(RefusalStrings.noWindowOpen) }
        let said = run.result.map { fields in ActionEffect.applied(result: { .success(fields.mapValues(ActionResultValue.string)) }) } ?? .done
        for pane in window.content?.panes.values.map({ $0 }) ?? [] {
            if let tab = pane.pane.tabs.first(where: { ScreenshotsPageAddress.matches($0.url.flatMap(URL.init(string:))) }) {
                if run.selects { pane.select(StripTabID(tab.id)) }
                return said
            }
        }
        return window.focusedPane?.newBrowserTab(url: ScreenshotsPageAddress.url, background: !run.selects) == true ? said : .done
    }

    func makePage(key: String, engine: BrowserEngineKind, profile: BrowserProfileID) -> ScreenshotsPageTab {
        let model = ScreenshotsModel(listsAtOnce: false) // lists after the person's click (ScreenshotsView's prompt)
        let page = ScreenshotsPageTab(id: BrowserTabID(rawValue: key), engine: engine, profile: profile, model: model,
                                      cache: thumbnails, workspace: workspace, files: files)
        page.onClose = { [weak self] in self?.pages.removeValue(forKey: key) }
        pages[key] = page
        followSettings()
        let settings = settings()
        if let detected, detected.settings == settings {
            model.setSources(detected.sources)
        } else {
            detect(settings)
        }
        return page
    }

    private func settings() -> ScreenshotsSettings {
        services?.settings?.snapshot.screenshots ?? ScreenshotsSettings()
    }

    /// Re-arms on each `screenshots.*` change for as long as the service lives.
    private func followSettings() {
        guard !followsSettings, let settings = services?.settings else { return }
        followsSettings = true
        withObservationTracking {
            _ = settings.snapshot.screenshots
        } onChange: { [weak self] in
            // task-owner: one hop per settings change; re-arms itself while the service lives
            Task { @MainActor [weak self] in
                guard let self else { return }
                followsSettings = false
                followSettings()
                let settings = self.settings()
                if detected?.settings != settings { detect(settings) }
            }
        }
    }

    /// Finds the folders for `settings` off the main actor and gives them to every open page.
    /// Pages opened later reuse them until the settings change.
    private func detect(_ settings: ScreenshotsSettings) {
        detection?.cancel()
        let detector = detector
        // task-owner: `detection`; a newer detection cancels this one
        detection = Task { [weak self] in
            let sources = await Self.detectSources(detector, settings)
            guard !Task.isCancelled, let self else { return }
            detected = (settings, sources)
            for page in pages.values { page.model.setSources(sources) }
        }
    }

    /// Reads preferences and settings files and checks folders: file system work, off the main actor.
    @concurrent
    private nonisolated static func detectSources(_ detector: ScreenshotSourceDetector, _ settings: ScreenshotsSettings) async -> [ScreenshotSource] {
        detector.detect(findTools: settings.findTools, extraFolders: settings.folders)
    }
}
