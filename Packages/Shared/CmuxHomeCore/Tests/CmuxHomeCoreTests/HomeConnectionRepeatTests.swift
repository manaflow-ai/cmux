import Foundation
import Observation
import os
import Testing
@testable import CmuxHomeCore

/// A connection event that does not change the kind of connection is no new information
/// (speed-of-sound-DESIGN.md 1: work follows what changed). An owner that is down reports
/// offline again on each failed reconnect, each time with a new `since`
/// (`DaemonHomeSource.connectionChanged(nil)`, `CloudHomeSource`, `WireHomeSource`), and the
/// router passes it on because the dates differ. Before, each one assigned `connection` (every
/// view that reads it rendered again), cleared typing and every transcript cache, marked the log
/// disconnected again and rebuilt every inbox row.
@MainActor
@Suite struct HomeConnectionRepeatTests {
    @Test func offlineAgainChangesNothing() {
        let store = HomeStore(source: MockHomeSource(options: .immediate))
        let since = Date(timeIntervalSince1970: 100)
        store.handle(.connection(.offline(since: since)))
        #expect(store.connection == .offline(since: since))

        let changed = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = store.connection
            _ = store.rows
        } onChange: { changed.withLock { $0 = true } }
        for second in 1...20 {
            store.handle(.connection(.offline(since: since.addingTimeInterval(Double(second)))))
        }
        #expect(!changed.withLock { $0 }, "offline after offline notified the store's observers")
        #expect(store.connection == .offline(since: since), "the store stays offline since it first went offline")
    }

    @Test func connectingAgainChangesNothing() {
        let store = HomeStore(source: MockHomeSource(options: .immediate))
        store.handle(.connection(.connecting))
        let changed = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = store.connection
            _ = store.rows
        } onChange: { changed.withLock { $0 = true } }
        store.handle(.connection(.connecting))
        #expect(!changed.withLock { $0 }, "connecting after connecting notified the store's observers")
    }

    /// The kind still matters: going online after offline is a change, and so is offline after
    /// online (with its own `since`).
    @Test func aRealChangeStillApplies() {
        let store = HomeStore(source: MockHomeSource(options: .immediate))
        store.handle(.connection(.offline(since: Date(timeIntervalSince1970: 100))))
        store.handle(.connection(.online))
        #expect(store.connection == .online)
        let later = Date(timeIntervalSince1970: 300)
        store.handle(.connection(.offline(since: later)))
        #expect(store.connection == .offline(since: later))
    }
}
