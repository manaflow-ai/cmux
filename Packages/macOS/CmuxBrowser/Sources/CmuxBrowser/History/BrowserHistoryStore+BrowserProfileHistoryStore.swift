/// Conforms ``BrowserHistoryStore`` to the ``BrowserProfileHistoryStore`` seam so
/// the profile repository can manage per-profile history stores through the seam
/// without naming the concrete history store. The store already implements the
/// seam's `clearHistoryWithoutLoadingPersistedFile()`, `cancelPendingSaves()`, and
/// `flushPendingSaves()` lifecycle members, so the conformance is empty.
extension BrowserHistoryStore: BrowserProfileHistoryStore {}
