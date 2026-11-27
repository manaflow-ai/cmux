@testable import CmuxNextDaemon
import Testing

/// startup-matrix cut 2: a cold launch's first tree came ~430 ms after the connect, against ~90 warm. The launch
/// marks name where the store's first snapshot came from, so the next nightly shows whether the prestart's
/// prefetch was used, dropped and fetched again, or never made.
@Suite struct StoreSnapshotSourceMarkTests {
    @Test func usedPrefetchIsNamed() {
        #expect(DaemonConnection.snapshotSourceMark(hadPrefetch: true, usedPrefetch: true) == "daemon.store_snapshot.prefetched")
    }

    @Test func droppedPrefetchIsNamedApartFromNoPrefetch() {
        #expect(DaemonConnection.snapshotSourceMark(hadPrefetch: true, usedPrefetch: false) == "daemon.store_snapshot.prefetch_dropped")
        #expect(DaemonConnection.snapshotSourceMark(hadPrefetch: false, usedPrefetch: false) == "daemon.store_snapshot.fetch_start")
    }
}
