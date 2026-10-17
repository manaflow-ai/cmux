import CoreGraphics
import Foundation

/// Tabs and downloads Chromium starts for no cmux page: an extension's
/// background worker (`chrome.tabs.create`, `chrome.downloads.download`),
/// the welcome page an extension opens after its install, a tab created
/// before any Chromium page exists.
///
/// A tab joins the Chromium window of the page `unownedTabAnchor` names
/// (the focused Chromium page of the request's profile), so the extension
/// keeps a real tab, and that page's owner places it beside the page
/// (`.newBrowser`, as for a link's tab). Without such a page its URL opens
/// through `openUnownedURL` as a new cmux Chromium tab. A download goes to
/// the same page, so it shows in that panel's downloads list; without one it
/// goes straight into the Downloads folder.
///
/// Reference: cmux Next `CmuxNextBrowser/CEF/CEFOrphanTabs.swift`,
/// `CEFWindowPolicy.swift` and `CEFDownloads.swift` (`forRuntime`).
extension CEFRuntime {
    /// Chromium wants a window or tab (fork API 8): a request no live page
    /// made goes to the anchor page or a new cmux tab; the rest go to
    /// `windowRequest`.
    func routeWindowRequest(kind: Int32, disposition: Int32, source: Int32, url: String,
                            bounds: CGRect? = nil, profilePath: String) -> Int32 {
        if let window = unownedWindowRequest(kind: kind, disposition: disposition, source: source, url: url,
                                             profilePath: profilePath) {
            return window
        }
        return windowRequest(kind: kind, disposition: disposition, source: source, url: url, bounds: bounds)
    }

    /// The window an unowned request's tab joins (0: none, the URL opens in a
    /// new cmux tab), or nil when a live page asked or the request is for an
    /// incognito window (cmux opens no incognito window: `windowRequest`).
    private func unownedWindowRequest(kind: Int32, disposition: Int32, source: Int32, url: String,
                                      profilePath: String) -> Int32? {
        if let page = browsers[source], !page.isClosed { return nil }
        guard kind != 3 else { return nil }
        let profile = storage.profile(forPath: profilePath)
        if let anchor = unownedTabAnchor?(profile), let id = anchor.browserID,
           Self.canTakeUnownedTab(anchor, registered: browsers[id], profilePath: profilePath) {
            logger.notice("CEF tab without a cmux opener (kind \(kind), source \(source)) joins browser \(id)")
            return id
        }
        logger.notice("CEF tab without a cmux opener (kind \(kind), source \(source)) opens in a new cmux tab")
        if let target = URL(string: url), !url.isEmpty {
            let placement = Self.unownedDisposition(CEFDisposition(raw: Int(disposition)))
            // Not from inside Chromium's request (it must not create browsers).
            Task { @MainActor [weak self] in self?.openUnownedURL?(target, placement, profile) }
        }
        return 0
    }

    /// A live page of the request's store: Chromium inserts the tab into
    /// that page's window, so it must hold the same profile.
    nonisolated static func sameStore(contextKey: String, profilePath: String) -> Bool {
        guard !profilePath.isEmpty else { return true }
        guard contextKey.hasPrefix("/") else { return false }
        func normalized(_ path: String) -> String {
            URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        }
        return normalized(contextKey) == normalized(profilePath)
    }

    private static func canTakeUnownedTab(_ anchor: CEFBrowser, registered: CEFBrowser?, profilePath: String) -> Bool {
        registered === anchor && !anchor.isClosed && !anchor.isPlaceholder && !anchor.awaitsWindowMove
            && sameStore(contextKey: anchor.contextKey, profilePath: profilePath)
    }

    /// A window or popup request opens as a tab: cmux has no Chromium windows.
    nonisolated static func unownedDisposition(_ disposition: CEFDisposition) -> CEFDisposition {
        disposition == .newBackgroundTab ? .newBackgroundTab : .newForegroundTab
    }

    // MARK: Downloads

    /// A download event of no live page (browser 0: a background worker's
    /// `chrome.downloads.download`), or of one routed here when it started.
    func routeUnownedDownload(_ event: CEFShimEvent, token: Int32) {
        guard case .download(let kind, let browser, _, _, _, let url, let suggestedName) = event else { return }
        switch kind {
        case 34 where unownedDownloads.route(for: token) == nil:
            if let anchor = unownedTabAnchor?(nil), let id = anchor.browserID, browsers[id] === anchor, !anchor.isClosed {
                logger.notice("CEF download \(token) of browser \(browser) shows in browser \(id)")
                unownedDownloads.begin(token, .page(id))
                anchor.handle(event)
                return
            }
            let directory = unownedDownloadDirectory()
            let file = CEFUnownedDownloads.destination(suggestedName: suggestedName, url: url, in: directory) {
                FileManager.default.fileExists(atPath: $0.path)
            }
            logger.notice("CEF download \(token) of browser \(browser) has no page; saving it in the Downloads folder")
            unownedDownloads.begin(token, .file(file))
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            continueDownload(token: token, to: file.path)
        default:
            guard let route = unownedDownloads.route(for: token) else { return }
            if kind == 36 { unownedDownloads.end(token) }
            switch route {
            case .page(let id):
                // The page closed meanwhile: it cancelled its downloads.
                browsers[id]?.handle(event)
            case .file(let file):
                // Chromium resuming an interrupted download asks again: same file.
                if kind == 34 { continueDownload(token: token, to: file.path) }
                if kind == 36 { logger.notice("CEF download \(token) into \(file.lastPathComponent, privacy: .private) ended (\(event.downloadEnd))") }
            }
        }
    }
}

private extension CEFShimEvent {
    /// A download end's state (1 complete, 2 cancelled, 3 interrupted).
    var downloadEnd: Int64 {
        if case .download(_, _, _, let a, _, _, _) = self { return a }
        return 0
    }
}

/// Downloads Chromium started for no cmux page, and where each went.
struct CEFUnownedDownloads {
    enum Route: Equatable {
        /// Shown and saved by this page (Chromium browser id).
        case page(Int32)
        /// Saved straight into this file.
        case file(URL)
    }

    private var routes: [Int32: Route] = [:]

    func route(for token: Int32) -> Route? { routes[token] }

    mutating func begin(_ token: Int32, _ route: Route) { routes[token] = route }

    mutating func end(_ token: Int32) { routes[token] = nil }

    /// A file in `directory` for the download: Chromium's suggested name
    /// (its last path component only), else the URL's, else "download",
    /// numbered like Finder ("name (1).ext") when the name is taken.
    static func destination(suggestedName: String, url: String, in directory: URL,
                            exists: (URL) -> Bool) -> URL {
        func lastComponent(_ text: String) -> String {
            let name = (text as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
            return name == "/" || name == "." || name == ".." ? "" : name
        }
        var name = lastComponent(suggestedName)
        if name.isEmpty, let path = URL(string: url)?.path { name = lastComponent(path) }
        if name.isEmpty { name = "download" }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = directory.appendingPathComponent(name)
        var number = 1
        while exists(candidate) {
            let numbered = "\(base) (\(number))" + (ext.isEmpty ? "" : "." + ext)
            candidate = directory.appendingPathComponent(numbered)
            number += 1
        }
        return candidate
    }
}
