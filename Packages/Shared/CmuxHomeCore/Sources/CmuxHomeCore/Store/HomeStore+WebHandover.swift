import Foundation

// The sends a web composer (the Messages page) takes over from this store. The page keeps its own
// outbox (the pending web sends, HomeStore+Cache) and never reads this store's log, so a send of the
// log it is not handed would vanish from the person's view. Each one leaves the log as it is handed
// over (it never shows or goes from both), and its key comes with it, so a retry from the page is
// the same send to the owner (its ledger applies a key once).
extension HomeStore {
    /// The log's text send under `key` as the cache keeps it; nil when there is none (acknowledged,
    /// uploading, or with a non-text part).
    public func cachedSend(_ key: IdempotencyKey) -> HomeCachedSend? {
        log.entries.first { $0.intent.key == key }.flatMap(HomeCachedSend.init)
    }

    /// Every Not Delivered text send of the log (the native composer's, a first send a host made),
    /// oldest first, taken out of the log.
    public func takeFailedTextSends() -> [HomeCachedSend] {
        let taken = log.entries.compactMap { entry -> HomeCachedSend? in
            guard case .failed = entry.state else { return nil }
            return HomeCachedSend(entry)
        }
        for send in taken { discardFailed(send.key) }
        return taken
    }
}
