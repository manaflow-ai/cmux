import Foundation
@testable import CmuxNextFilesUI
import Testing

/// The Files pane's Quick Look panel-control callbacks run through ``QuickLookControlCall``: a call on
/// the main thread (QLPreviewPanel's own) does the work before it returns, so the panel finds its data
/// source set; a call off main hops to the main actor instead of trapping.
@MainActor
struct QuickLookControlCallTests {
    @MainActor private final class Flag {
        var ran = false
    }

    @Test func onTheMainThreadTheWorkRunsBeforeTheCallReturns() {
        let flag = Flag()
        QuickLookControlCall().run { flag.ran = true }
        #expect(flag.ran)
    }

    @Test func offTheMainThreadTheWorkRunsOnTheMainActor() async {
        let onMain = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            Thread.detachNewThread {
                QuickLookControlCall().run { done.resume(returning: Thread.isMainThread) }
            }
        }
        #expect(onMain)
    }
}
