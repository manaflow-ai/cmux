import CmuxNextAgentPane
@testable import CmuxNextCompat
import Foundation
import Testing

#if DEBUG || CMUX_BLOCKING_CHECKS
extension SavedEnvironments {
    /// The blocking context the store's own methods run in.
    fileprivate func blockingContext() -> BlockingContext { BlockingContext.current() }
}

/// The saved environments' file reads and writes block the store's own serial queue, never a cooperative pool
/// thread (p02-threads-141..144, R4; Chrome runs file work on a MayBlock sequence, base/task/task_traits.h).
struct SavedEnvironmentsExecutorTests {
    @Test func itsMethodsRunOnItsOwnQueueNotThePool() async {
        let store = SavedEnvironments(url: FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json"))
        #expect(await store.blockingContext() == .dedicated)
    }
}
#endif
