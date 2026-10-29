import struct CmuxSafeConcurrency.OwnerReference
import CmuxNextBrowser
import CmuxNextControl
import CmuxNextSettings
import CmuxNextWakeups

/// `browser.page.*` (CmuxNextControl/Browser) for the app's browser tabs.
nonisolated struct AppBrowserPageEngine: BrowserPageEngine {
    private let servicesReference: OwnerReference<AppServices>
    /// The app's services, which own this; nil (reported) only once they are gone.
    var services: AppServices? { servicesReference.resolve() }
    /// The app's main-thread scheduler: the agent cursor is posted on it.
    private let mainWork: MainWorkScheduler

    @MainActor init(services: AppServices) {
        servicesReference = OwnerReference(services: services)
        mainWork = services.mainWork
    }

    func run(_ operation: BrowserPageOperation, tabID: String, url: String?) async throws -> JSONValue {
        guard let services else { throw ActionFailure.appClosing }
        return try await AppBrowserPage.run(operation, tabID: tabID, services: services)
    }

    func downloads(_ query: BrowserPageDownloadQuery) async throws -> BrowserPageDownloads {
        guard let services else { throw ActionFailure.appClosing }
        return try await AppBrowserPageEngine.downloads(query, services: services)
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

    /// The agent cursor is an agent's work: one automation task, in order with the request's other posts, so it
    /// never takes the person's frame (p06-scheduler.md section D).
    func announce(_ input: BrowserPageAgentInput, tabID: String) async {
        let servicesReference = servicesReference
        mainWork.postFromAnyThread(.automation, owner: "browser.page.agent_cursor") {
            servicesReference.resolve()?.browserHost?.pageInputCursor.publish(input, tabID: tabID)
        }
    }
}
