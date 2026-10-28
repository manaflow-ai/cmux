import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextFileGrid
import CmuxNextFiles
import CmuxNextScreenshots
import CmuxNextSettings
import CmuxNextWakeups
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
    /// The thumbnail cache's memory consumer registration (`memoryFileHomeCaches`; nil while off).
    private var thumbnailsMemory: AsyncMemoryConsumerRegistration?
    private let workspace = AppScreenshotsWorkspace()
    /// Drops, renames and trashes go through the Files pane's operations.
    private let files: FileOperator
    private let detector = ScreenshotSourceDetector(environment: SystemScreenshotEnvironment())
    /// Open pages by tab key.
    private var pages: [String: ScreenshotsPageTab] = [:]
    /// The last folders found, and the settings they were found for.
    private var detected: (settings: ScreenshotsSettings, sources: [ScreenshotSource])?
    /// The detection running; a newer one cancels it, and ``detectionGeneration`` drops its late result.
    private var detection: Task<Void, any Error>?
    private var detectionGeneration: UInt64 = 0
    /// The `screenshots.*` settings, followed from the first page on (``followSettings()``).
    private var settingsWatch: FrameObservation<ScreenshotsSettings>?
    /// The app's main-thread scheduler: each page's model lands its reads on it, and its grid follows the model on it.
    private let mainWork: MainWorkScheduler

    init(services: AppServices) {
        self.services = services
        mainWork = services.mainWork
        thumbnailsMemory = AppMemoryConsumers(services: services).registerFileGridThumbnails(thumbnails)
        files = FileOperator(work: services.work)
    }

    /// Selects the active window's Screenshots tab, else opens one beside the
    /// focused tab.
    ///
    /// - Parameter focus: select the tab (a person's run); off, an agent or the
    ///   CLI opens it in the background and keeps the person's focus.
    func open(focus: Bool) {
        guard let services else { return }
        guard let window = services.windows.active else { return services.registry.refuse(RefusalStrings.noWindowOpen) }
        for pane in window.content?.panes.values.map({ $0 }) ?? [] {
            if let tab = pane.pane.tabs.first(where: { ScreenshotsPageAddress.matches($0.url.flatMap(URL.init(string:))) }) {
                if focus { pane.select(StripTabID(tab.id)) }
                return
            }
        }
        guard let pane = window.focusedPane else { return }
        pane.newBrowserTab(url: ScreenshotsPageAddress.url, background: !focus)
    }

    func makePage(key: String, engine: BrowserEngineKind, profile: BrowserProfileID) -> ScreenshotsPageTab {
        let model = ScreenshotsModel(mainWork: mainWork)
        let page = ScreenshotsPageTab(id: BrowserTabID(rawValue: key), engine: engine, profile: profile, model: model,
                                      cache: thumbnails, workspace: workspace, files: files, mainWork: mainWork)
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

    /// Follows the `screenshots.*` settings for as long as the service lives, from the first page on: one
    /// `.automation` apply per change (open pages in hidden windows update too; the detection runs off main).
    private func followSettings() {
        guard settingsWatch == nil, let services, services.settings != nil else { return }
        settingsWatch = FrameObservation(owner: "screenshots.settings", delivery: .automation, on: services.mainWork) { [weak self] in
            self?.settings() ?? ScreenshotsSettings()
        } onChange: { [weak self] settings in
            guard let self, detected?.settings != settings else { return }
            detect(settings)
        }
    }

    /// Finds the folders for `settings` off the main actor and gives them to every open page.
    /// Pages opened later reuse them until the settings change.
    private func detect(_ settings: ScreenshotsSettings) {
        guard let services else { return }
        detection?.cancel()
        detectionGeneration &+= 1
        let detector = detector, generation = detectionGeneration, mainWork = services.mainWork
        // task-owner: `detection`; a newer detection cancels this one. R-hop: the folders are found off main; the
        // pages get them in one visible task (open pages show them).
        detection = services.work.task(.userVisible) { [weak self] in
            let sources = await Self.detectSources(detector, settings)
            try Task.checkCancellation()
            mainWork.postFromAnyThread(.visible, owner: "ScreenshotsPageService.detected") { [weak self] in
                self?.detected(sources, for: settings, generation: generation)
            }
        }
    }

    /// The folders for `settings` were found: every open page shows them, unless a newer detection started.
    private func detected(_ sources: [ScreenshotSource], for settings: ScreenshotsSettings, generation: UInt64) {
        guard generation == detectionGeneration else { return }
        detected = (settings, sources)
        for page in pages.values { page.model.setSources(sources) }
    }

    /// Reads preferences and settings files and checks folders: file system work, off the main actor.
    @concurrent
    private nonisolated static func detectSources(_ detector: ScreenshotSourceDetector, _ settings: ScreenshotsSettings) async -> [ScreenshotSource] {
        detector.detect(findTools: settings.findTools, extraFolders: settings.folders)
    }
}
