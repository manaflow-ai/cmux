public import CmuxNextBrowserCore
public import Foundation

/// A profile's omnibox history persistence: the daemon's visit store (`history-v1`). Its writes go
/// into the history's one ordered queue (``HistoryWriteQueue``), with every other profile's and
/// every clear and remove, so a title never overtakes the visit it names and a clear covers the
/// visits made before it. A visit keeps the time it was made (`at_ms`).
public final class DaemonVisitSink: BrowserHistoryPersistence {
    /// A page removed from the history (Remove from History, Shift-Delete in the omnibar): the
    /// import store drops its imported copy too, so it does not come back at the next launch.
    public var onRemove: ((URL) -> Void)?
    private let profile: String
    private let writes: HistoryWriteQueue<DaemonHistoryClient>

    public init(profile: String, writes: HistoryWriteQueue<DaemonHistoryClient>) {
        self.profile = profile
        self.writes = writes
    }

    public func didRecordVisit(url: URL, title: String?, at date: Date) {
        let profile = profile, text = url.absoluteString
        writes.enqueue(visit: true) { try await $0.recordVisit(profile: profile, url: text, title: title, tab: nil, at: date, key: $1) }
    }

    public func didUpdateTitle(_ title: String, for url: URL) {
        let profile = profile, text = url.absoluteString
        writes.enqueue(visit: true) { try await $0.updateTitle(profile: profile, url: text, title: title, key: $1) }
    }

    public func didRemoveEntry(for url: URL) {
        onRemove?(url)
        let profile = profile, text = url.absoluteString
        writes.enqueue { try await $0.removeVisits(profile: profile, url: text, key: $1) }
    }
}
