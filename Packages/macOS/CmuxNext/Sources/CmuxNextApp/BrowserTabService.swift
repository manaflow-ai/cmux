import CmuxNextBrowser
import CmuxNextDaemon
import Foundation

/// The daemon's engine tag (the browser module has an engine protocol of the same name).
typealias BrowserEngineTag = CmuxNextDaemon.BrowserEngine

/// Daemon-owned browser tabs (`frontend-browser-tabs-v1`): creation with an
/// engine choice, and the debounced url/title/favicon write-back that lets
/// the daemon restore them after relaunch. The command closures are seams
/// for tests.
final class BrowserTabService {
    /// `new-frontend-browser-tab` in `pane`. Returns the new surface.
    var create: @MainActor (_ pane: PaneID, _ url: String, _ engine: BrowserEngineTag) async throws -> SurfaceID
    /// `update-frontend-browser-tab`. Returns false when the command failed.
    var update: @MainActor (SurfaceID, BrowserRecordUpdate) async -> Bool
    /// Whether the daemon serves `frontend-browser-tabs-v1`.
    var isAvailable: @MainActor () -> Bool
    /// Whether the CEF runtime is bundled and can start.
    var cefAvailable: @MainActor () -> Bool
    var writeBackDelay: Duration = .milliseconds(500)
    var sleep: BrowserRecordWriter.Sleep = { try await ContinuousClock().sleep(for: $0) }
    private var writers: [String: BrowserRecordWriter] = [:]

    init(daemon: DaemonService, cef: CEFEngine) {
        create = { [weak daemon] pane, url, engine in
            guard let connection = daemon?.connection else { throw DaemonError.notConnected }
            return try await connection.newFrontendBrowserTab(url: url, engine: engine, in: pane).surface
        }
        update = { [weak daemon] surface, update in
            await daemon?.run("update-frontend-browser-tab") { connection in
                _ = try await connection.updateFrontendBrowserTab(surface, url: update.url, title: update.title, faviconURL: update.favicon)
            } ?? false
        }
        isAvailable = { [weak daemon] in daemon?.supports(DaemonCapabilities.frontendBrowserTabs) ?? false }
        cefAvailable = { [weak cef] in cef?.availability == .available }
    }

    /// The engine for a request: CEF only when asked for and available,
    /// else WebKit (the default).
    func engine(requested: String?) -> BrowserEngineTag {
        requested == BrowserEngineTag.cef.rawValue && cefAvailable() ? .cef : .webkit
    }

    /// Starts writing `page` back to the daemon record of `tab` (keyed by
    /// tab id; one writer per live page).
    func track(_ page: any BrowserTab, for tab: TabModel) {
        guard tab.isFrontendOwned, writers[tab.id] == nil else { return }
        let update = update
        // The surface is read at send time: a moved tab keeps its record.
        writers[tab.id] = BrowserRecordWriter(tab: page, recorded: BrowserRecord(tab: tab), delay: writeBackDelay, sleep: sleep) { [weak tab] fields in
            guard let tab else { return false }
            return await update(tab.surface, fields)
        }
    }

    /// The page was released: stop writing.
    func untrack(_ key: String) {
        writers.removeValue(forKey: key)?.cancel()
    }

    func isTracking(_ key: String) -> Bool { writers[key] != nil }
}
