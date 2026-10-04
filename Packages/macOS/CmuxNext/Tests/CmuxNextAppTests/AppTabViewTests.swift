import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import Observation
import Testing

/// An `app` tab follows the app registry: a placeholder until the app is
/// listed, its page as soon as it is, the placeholder again when the app
/// goes away. And the app workspace wait ends on the tree or on the clock.
@MainActor
struct AppTabViewTests {
    @Observable @MainActor final class FakeRegistry {
        var state: AppTabView.State = .loading
    }

    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<1000 where !condition() { await Task.yield() }
    }

    @Test func aTabRestoredBeforeTheScanShowsThePageWhenTheAppIsListed() async {
        let registry = FakeRegistry()
        var mounts = 0, unmounts = 0
        let view = AppTabView(state: { registry.state }, mount: { mounts += 1; return NSView() }, unmount: { unmounts += 1 })
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        #expect(view.state == .loading)
        #expect(view.page == nil)
        #expect(view.focusTarget === view)

        registry.state = .ready
        await settle { view.page != nil }
        #expect(view.page?.superview === view)
        #expect(mounts == 1)
        #expect(view.focusTarget === view.page)

        registry.state = .unavailable
        await settle { view.page == nil }
        #expect(unmounts == 1)
        #expect(view.state == .unavailable)

        view.stop()
        #expect(mounts == 1)
    }

    @Test func stoppingReleasesAMountedPage() {
        var unmounts = 0
        let view = AppTabView(state: { .ready }, mount: { NSView() }, unmount: { unmounts += 1 })
        #expect(view.page != nil)
        view.stop()
        #expect(view.page == nil)
        #expect(unmounts == 1)
    }

    @Test func theAppWorkspaceWaitTimesOutOnTheClock() async {
        let clock = ManualClock()
        let store = DaemonStore()
        let wait = Task { try await AppsService.waitForWorkspace(ResourceID(rawValue: "workspace_9"), in: store, timeout: .seconds(10), clock: clock) }
        await clock.sleepers(atLeast: 1)
        clock.advance(by: .seconds(10))
        await #expect(throws: AppScreenError.timedOut) { try await wait.value }
        #expect(AppScreenError.timedOut.errorDescription == RefusalStrings.appWorkspaceTimedOut)
    }

    @Test func theAppWorkspaceWaitEndsWhenTheTreeReportsIt() async throws {
        let clock = ManualClock()
        let store = DaemonStore()
        let id = ResourceID(rawValue: "workspace_9")
        let wait = Task { try await AppsService.waitForWorkspace(id, in: store, timeout: .seconds(10), clock: clock) }
        await clock.sleepers(atLeast: 1)
        let workspace = WorkspaceSnapshot(id: 1, key: WorkspaceKey(rawValue: "0b6c4a52-6d3f-4c55-9d53-8f1f4e0f1a02"), resourceID: id, name: "App Store")
        store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: [workspace]))
        let found = try await wait.value
        #expect(found == store.workspaces.first?.id)
    }
}
