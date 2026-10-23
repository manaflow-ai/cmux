import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextSidebar
import CmuxNextTabs
import Testing

/// A view released off the main thread still cancels its observation tasks in its `nonisolated deinit`
/// (the deinit had `guard Thread.isMainThread else { return }`, so such a release leaked every task).
@MainActor @Suite(.serialized) struct OffMainReleaseCleanupTests {
    /// Holds the only reference until a background task drops it there.
    private nonisolated final class Holder: @unchecked Sendable { // test only: the main actor sets it once, one detached task clears it
        var view: NSView?
    }

    /// Hands `make()`'s view to a detached task as its last reference, then answers its observation tasks.
    private func releaseOffMain(_ make: () -> (NSView, [Task<Void, Never>?])) async -> [Task<Void, Never>] {
        let holder = Holder()
        var tasks: [Task<Void, Never>] = []
        // AppKit autoreleases views it touches: drained here, so the detached task's release is the last one.
        autoreleasepool {
            let (view, observed) = make()
            tasks = observed.compactMap { $0 }
            holder.view = view
        }
        let offMain = await Task.detached { () -> Bool in
            holder.view = nil
            return !Thread.isMainThread
        }.value
        #expect(offMain, "the release ran on the main thread")
        return tasks
    }

    @Test func aWorkspaceContentViewReleasedOffMainCancelsItsObservation() async {
        let tasks = await releaseOffMain {
            let view = WorkspaceContentView(layoutView: NSView(), bar: TabStripView(model: TabStripModel()))
            return (view, [view.tokenObservation])
        }
        #expect(!tasks.isEmpty)
        #expect(tasks.allSatisfy { $0.isCancelled }, "an off-main release leaked the workspace view's observation")
    }

    @Test func aPaneContentViewReleasedOffMainCancelsItsObservations() async {
        let tasks = await releaseOffMain {
            let view = PaneContentView(stripModel: TabStripModel(), reveal: LaunchReveal(deadline: .zero))
            return (view, [view.tokenObservation, view.placementObservation, view.paneBackgroundsObservation, view.agentTagObservation])
        }
        #expect(!tasks.isEmpty)
        #expect(tasks.allSatisfy { $0.isCancelled }, "an off-main release leaked the pane view's observations")
    }

    @Test func aWindowRootViewReleasedOffMainCancelsItsObservations() async {
        _ = NSApplication.shared
        let tasks = await releaseOffMain {
            let view = WindowRootView(sidebar: SidebarContainerView(model: SidebarModel()))
            return (view, [view.tokenObservation, view.placementObservation, view.mainPaneObservation])
        }
        #expect(!tasks.isEmpty)
        #expect(tasks.allSatisfy { $0.isCancelled }, "an off-main release leaked the window root's observations")
    }
}
