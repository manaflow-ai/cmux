@testable import CmuxNextApp
@testable import CmuxNextCompat
import CmuxNextOnboarding
import Foundation
import Testing

#if DEBUG || CMUX_BLOCKING_CHECKS
extension MarkdownTableWidthRepository {
    /// The blocking context the repository's own methods run in.
    fileprivate func blockingContext() -> BlockingContext { BlockingContext.current() }
}

extension ClassicMigrationRepository {
    /// The blocking context the repository's own methods run in.
    fileprivate func blockingContext() -> BlockingContext { BlockingContext.current() }
}

/// Actors whose job is file work run on their own serial queue, so their file calls never hold a cooperative pool
/// thread (p02-threads-141..144, R4; Chrome runs file work on a MayBlock sequence, base/task/task_traits.h). On the
/// default actor executor each method runs on the pool, where the blocking detector records every file call.
struct BlockingActorExecutorTests {
    @Test func tableWidthsRunOnTheirOwnQueue() async {
        let repository = MarkdownTableWidthRepository(fallback: nil)
        #expect(await repository.blockingContext() == .dedicated)
    }

    @Test func theClassicMigrationRepositoryRunsOnItsOwnQueue() async {
        let repository = ClassicMigrationRepository(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        #expect(await repository.blockingContext() == .dedicated)
    }
}
#endif
