import CmuxNextSignposts
@testable import CmuxNextTrace
import Testing

/// CmuxNextTrace sits below the catalog, so the global-enqueue hook repeats `task.post`'s id and the task
/// category's bit; this pins the copies to the catalog.
@Suite("Concurrency hook catalog")
struct ConcurrencyHookCatalogTests {
    @Test("The hook writes task.post under the task category's bit")
    func hookUsesCatalogValues() {
        #expect(ConcurrencyHook.taskPostName == SignpostName.taskPost.rawValue)
        #expect(ConcurrencyHook.taskCategoryBit == SignpostCategory.task.traceBit)
        #expect(SignpostName.taskPost.traceCategory == .task)
    }
}
