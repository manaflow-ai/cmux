import CmuxNextWakeups
import Testing
@testable import CmuxNextDaemon

/// The local daemon's store names its connection epoch in the crash keys
/// (``CrashKeySlots/Key/daemonEpoch``): a crash record says which connection the app was on.
@MainActor
struct DaemonEpochCrashKeyTests {
    @Test func eachConnectionChangeMovesTheEpochKey() {
        let keys = CrashKeySlots()
        let store = DaemonStore(crashKeys: keys)
        #expect(keys.value(.daemonEpoch) == 0, "no connection yet")
        _ = DaemonConnectionChange.disconnected("socket closed").apply(to: store)
        #expect(keys.value(.daemonEpoch) == UInt64(store.connectionEpoch))
        _ = DaemonConnectionChange.shutdown.apply(to: store)
        #expect(keys.value(.daemonEpoch) == UInt64(store.connectionEpoch))
        #expect(store.connectionEpoch == 2)
    }
}
