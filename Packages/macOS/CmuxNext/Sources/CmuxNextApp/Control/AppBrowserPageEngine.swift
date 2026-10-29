import CmuxNextBrowser
import CmuxNextControl
import CmuxNextSettings

/// `browser.page.*` (CmuxNextControl/Browser) for the app's browser tabs.
nonisolated struct AppBrowserPageEngine: BrowserPageEngine {
    unowned let services: AppServices

    func run(_ operation: BrowserPageOperation, tabID: String, url: String?) async throws -> JSONValue {
        try await AppBrowserPage.run(operation, tabID: tabID, services: services)
    }

    func downloads(_ query: BrowserPageDownloadQuery) async throws -> BrowserPageDownloads {
        try await AppBrowserPageEngine.downloads(query, services: services)
    }

    /// The App's downloads list (both engines), its waits in `BrowserDownloadWaits`.
    @MainActor private static func downloads(_ query: BrowserPageDownloadQuery, services: AppServices) async throws -> BrowserPageDownloads {
        let list = services.cache.pageRequests.downloads
        let row = { (item: BrowserDownload) in
            let (status, reason): (String, String?) = switch item.status {
            case .inProgress: ("in_progress", nil)
            case .finished: ("finished", nil)
            case .failed(let why): ("failed", why)
            case .cancelled: ("cancelled", nil)
            case .blocked(let why): ("blocked", why)
            }
            return BrowserPageDownload(id: item.id.uuidString, filename: item.filename, status: status, reason: reason, paused: item.isPaused,
                                       received: item.receivedBytes, total: item.totalBytes, url: item.sourceURL?.absoluteString,
                                       path: item.destination?.path(percentEncoded: false), tab: list.origin(of: item))
        }
        guard let limit = query.wait else {
            let rows = list.items.filter { query.tabID == nil || list.origin(of: $0) == query.tabID }
            return .list(Array(rows.suffix(max(query.limit ?? rows.count, 0))).map(row))
        }
        switch await list.waits.ended(id: query.id, tab: query.tabID, items: list.items, within: limit) {
        case .ended(let item): return .ended(row(item))
        case .unknownID: return .unknownID
        case .timedOut: return .timedOut
        }
    }

    func announce(_ input: BrowserPageAgentInput, tabID: String) async {
        await MainActor.run { services.browserHost?.pageInputCursor.publish(input, tabID: tabID) }
    }
}
