import CmuxNextBrowser
import CmuxNextControl
import CmuxNextSettings
import Foundation

/// `browser.page.downloads` and `browser.page.download.wait` (`cmux browser <tab|page> download …`) over
/// the App's one downloads list (`BrowserDownloadList`), both engines' downloads.
enum AppBrowserDownloads {
    /// A wait takes a download that started up to this long before it, so a click's download that started
    /// (or ended) before the agent's `download wait` is still the one it gets.
    static let recentStart: Duration = .seconds(60)

    static func answer(_ query: BrowserPageDownloadQuery, services: AppServices) async throws -> JSONValue {
        try await answer(query, list: services.cache.pageRequests.downloads)
    }

    static func answer(_ query: BrowserPageDownloadQuery, list: BrowserDownloadList,
                       clock: some Clock<Duration> = ContinuousClock()) async throws -> JSONValue {
        guard let limit = query.wait else {
            var rows = list.items.filter { query.tabID == nil || list.origin(of: $0) == query.tabID }
            if let count = query.limit { rows = Array(rows.suffix(max(count, 0))) }
            return ["downloads": .array(rows.map { row($0, list: list) })]
        }
        let deadline = clock.now.advanced(by: limit)
        let remaining = { clock.now.duration(to: deadline) }
        let item: BrowserDownload
        if let id = query.id {
            guard let found = list.items.first(where: { $0.id.uuidString.caseInsensitiveCompare(id) == .orderedSame }) else {
                throw ControlError(code: "not_found", message: "No download \(id)")
            }
            item = found
        } else if let recent = list.unreported(tab: query.tabID, since: .now - recentStart) {
            item = recent
        } else if let next = await within(remaining(), clock: clock, { take in list.onNextDownload(tab: query.tabID, take) }) {
            item = next
        } else {
            throw timedOut(limit)
        }
        list.markReported(item)
        guard await within(remaining(), clock: clock, { done in item.onFinish { _ in done(()) } }) != nil else { throw timedOut(limit) }
        let answer = row(item, list: list)
        guard item.status == .finished else {
            throw ControlError(code: "download_failed", message: "Download \(item.filename) did not finish: \(answer["status"]?.stringValue ?? "")",
                               data: answer)
        }
        return ["download": answer]
    }

    static func row(_ item: BrowserDownload, list: BrowserDownloadList) -> JSONValue {
        let (status, reason): (String, String?) = switch item.status {
        case .inProgress: ("in_progress", nil)
        case .finished: ("finished", nil)
        case .failed(let why): ("failed", why)
        case .cancelled: ("cancelled", nil)
        case .blocked(let why): ("blocked", why)
        }
        var row: [String: JSONValue] = [
            "id": .string(item.id.uuidString),
            "filename": .string(item.filename),
            "status": .string(status),
            "paused": .bool(item.isPaused),
            "received": .number(Double(item.receivedBytes)),
            "total": item.totalBytes.map { .number(Double($0)) } ?? .null,
            "url": item.sourceURL.map { .string($0.absoluteString) } ?? .null,
            "path": item.destination.map { .string($0.path(percentEncoded: false)) } ?? .null,
            "tab": list.origin(of: item).map(JSONValue.string) ?? .null,
        ]
        if let reason { row["reason"] = .string(reason) }
        return .object(row)
    }

    private static func timedOut(_ limit: Duration) -> ControlError {
        ControlError(code: "timeout", message: "No download ended within \(limit.components.seconds) s")
    }

    /// What `start` hands its callback, or nil once `limit` passes (an intentional bounded wait on the
    /// injected clock) or the call is cancelled. Answers once; later callbacks do nothing.
    private static func within<Value>(_ limit: Duration, clock: some Clock<Duration>,
                                      _ start: (@escaping (Value) -> Void) -> Void) async -> Value? {
        let once = Once<Value>()
        let timer = Task { @MainActor in
            try? await clock.sleep(for: limit)
            once.finish(nil)
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                once.wait(continuation)
                start { once.finish($0) }
            }
        } onCancel: {
            Task { @MainActor in once.finish(nil) }
        }
    }

    /// One answer for one waiting continuation.
    private final class Once<Value> {
        private var continuation: CheckedContinuation<Value?, Never>?
        private var answered: Value??

        /// Waits with `continuation`; at once when the answer came first (a cancel before the wait).
        func wait(_ continuation: CheckedContinuation<Value?, Never>) {
            if let answered { return continuation.resume(returning: answered) }
            self.continuation = continuation
        }

        func finish(_ value: Value?) {
            guard answered == nil else { return }
            answered = .some(value)
            if let continuation {
                self.continuation = nil
                continuation.resume(returning: value)
            }
        }
    }
}
