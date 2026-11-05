import CmuxNextWakeups
import Foundation

/// Work that runs after this pass's frame committed, and the creations it asks for. A Chromium browser made for a tab
/// that was just shown waits for the frame's commit (`CEFPaneHost.createAfterCommit`), so the tab's chrome shows in the
/// frame of the key that asked for it. When the tab is shown by work that already runs after that commit (a stand-in
/// tab's page, made once its key's frame committed), the commit is past: its browser is made when that work ends, in
/// the same pass, instead of at the main run loop's next idle pass (`AfterFrameCommit`'s observer is first called
/// there, and the run loop skips that stage on every pass that handled a source, so a busy main thread held a link's
/// `tab_add` 84 ms after the spare window's take on a cold launch and 246 ms under load, instant-new-surfaces
/// link_right). As Chrome runs the tasks posted after BeginMainFrame's commit then, never at UI-thread idle.
extension CEFRuntime {
    /// Runs `body`, work that runs after this pass's frame committed, then the creations it asked for
    /// (``afterCommit(_:)``). Nested, the outermost runs them.
    func afterFrameCommitted(_ body: () -> Void) {
        guard afterFrameWork == nil else { return body() }
        afterFrameWork = []
        body()
        let work = afterFrameWork ?? []
        afterFrameWork = nil
        for item in work { item() }
    }

    /// Runs `work` once this pass's frame committed: when the after-frame work running now ends
    /// (``afterFrameCommitted(_:)``), else after the commit (`AfterFrameCommit`).
    func afterCommit(_ work: @escaping @MainActor () -> Void) {
        if afterFrameWork != nil { afterFrameWork?.append(work) } else { AfterFrameCommit().run(work) }
    }
}

extension CEFEngine {
    /// Runs `body`, work that runs after this pass's frame committed (a stand-in tab's page, made once its key's frame
    /// committed): a Chromium browser it asks for starts when `body` ends, not at the next idle pass.
    public func afterFrameCommitted(_ body: () -> Void) {
        CEFRuntime.shared.afterFrameCommitted(body)
    }
}
