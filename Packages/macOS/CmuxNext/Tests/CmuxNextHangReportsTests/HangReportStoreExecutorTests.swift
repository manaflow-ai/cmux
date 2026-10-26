@testable import CmuxNextCompat
import CmuxNextHangReports
import Foundation
import Testing

#if DEBUG || CMUX_BLOCKING_CHECKS
extension HangReportStore {
    /// The blocking context the store's own methods run in.
    fileprivate func blockingContext() -> BlockingContext { BlockingContext.current() }
}

/// The store's file calls block its own serial queue, never a cooperative pool thread (p02-threads-141..144, R4:
/// Chrome runs file work on a MayBlock sequence, base/task/task_traits.h). On the default actor executor the same
/// method runs on the pool, where the blocking detector records every file call as a violation.
struct HangReportStoreExecutorTests {
    @Test func itsMethodsRunOnItsOwnQueueNotThePool() async {
        let store = HangReportStore(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        #expect(await store.blockingContext() == .dedicated)
    }
}
#endif
