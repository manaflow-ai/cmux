public import Foundation

/// Durable storage behind an in-memory history (the App's per-profile
/// visit log, plans/cmux-next/history.md). Incognito histories never get one.
public protocol BrowserHistoryPersistence: AnyObject {
    func didRecordVisit(url: URL, title: String?, at date: Date)
    func didUpdateTitle(_ title: String, for url: URL)
    func didRemoveEntry(for url: URL)
}
