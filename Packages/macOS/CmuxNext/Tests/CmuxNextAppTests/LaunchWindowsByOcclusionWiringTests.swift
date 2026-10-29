import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextFeatures
import CmuxNextLaunch
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// The app's wiring of `launchWindowsByOcclusion`, as `WindowManager.restore` runs it:
/// `scheduleLaunchBuilds` before the restore's `sync`. Before startup completes only the front window, a
/// window saved in full screen (it enters full screen at launch, never later under the person) and the
/// windows that show are built; a waiting window that shows holds startup as one loading window; reads
/// (the palette's names, `controller(for:)`) never build a waiting window; a waiting window closed before
/// its post is never built; and a waiting window's selection repair waits for its build.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct LaunchWindowsByOcclusionWiringTests {
    /// Every display a fleet Mac has contains these frames, so `WindowPlacementFallback` keeps them.
    private static let screens = [CGRect(x: 0, y: 0, width: 1920, height: 1080)]

    @MainActor private final class Launch {
        let scheduler: StartupTestScheduler
        let services: AppServices
        var windows: WindowManager { services.windows }

        /// Saved front to back: `front` builds now; `visible` overlaps it but is not inside it (it shows);
        /// `covered` is inside `front` (hidden); `full` was saved in full screen.
        init() {
            _ = NSApplication.shared
            let scheduler = StartupTestScheduler()
            let features = FeatureList(registry: FeatureRegistry(), channel: .dev,
                                       overrides: FeatureOverrides(environmentEnabled: [Feature.launchWindowsByOcclusion.name]))
            services = AppServices(environment: AppEnvironment.current([:]), launchStartup: scheduler.startup, features: features)
            self.scheduler = scheduler
            services.windows.ordersWindowsIn = false
            let saved = WindowRegistry(windows: [
                .init(id: "front", workspaceIDs: ["a"], frame: CGRect(x: 100, y: 100, width: 1000, height: 700)),
                .init(id: "visible", workspaceIDs: ["b1", "b2", "b3"], frame: CGRect(x: 50, y: 50, width: 500, height: 400)),
                .init(id: "covered", workspaceIDs: ["c"], frame: CGRect(x: 200, y: 200, width: 300, height: 200)),
                .init(id: "full", workspaceIDs: ["d"], frame: CGRect(x: 60, y: 60, width: 400, height: 300)),
            ])
            for window in saved.windows { services.windows.states[window.id] = WindowState(id: window.id) }
            services.windows.states["full"]?.restoresFullScreen = true
            services.windows.states["visible"]?.showWorkspace("b2")
            services.windows.registry.apply { registry in
                registry = saved
                return WindowRegistry.Changes()
            }
        }

        /// The restore's two steps.
        func restore() {
            windows.scheduleLaunchBuilds(screens: LaunchWindowsByOcclusionWiringTests.screens, appHidden: false)
            windows.sync(previous: [:])
        }

        var built: Set<String> { Set(windows.controllers.map(\.state.id)) }

        func tearDown() {
            scheduler.startup.beginQuit()
            for controller in windows.controllers { controller.window?.close() }
        }
    }

    /// Acceptance: 3 windows besides the full-screen one, 1 occluded: only the visible ones build before completion.
    @Test func onlyTheVisibleWindowsBuildBeforeStartupCompletes() throws {
        let launch = Launch()
        defer { launch.tearDown() }
        launch.restore()
        #expect(launch.built == ["front", "full"], "the restore's turn builds the front window and the full-screen one only")
        let queue = try #require(launch.windows.launchWindows)
        #expect(queue.waitingVisible == ["visible"])
        #expect(queue.waitingHidden == ["covered"])
        #expect(WindowInvariants.problems(launch.windows).isEmpty, "a waiting window is not an open window without a controller")

        let refs = VisiblePaneRefs(hold: { _ in { _ in } }, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        let stand = refs.windows(of: launch.windows).first { $0.id == "visible" }
        #expect(stand?.panes == [VisiblePaneRefs.Pane(key: "window:visible", state: .loading)],
                "the waiting window that shows holds startup as one loading window until it is built")

        launch.scheduler.startup.finishRegistration()
        launch.scheduler.startup.firstFrameCommitted()
        for _ in 0..<4 { launch.scheduler.fire() }
        #expect(launch.built == ["front", "full", "visible"], "the window that shows builds right after the first frame")
        #expect(launch.scheduler.startup.completion == nil)
        #expect(queue.waitingVisible.isEmpty, "built, it no longer stands in as a waiting window")

        launch.scheduler.hand.drain()
        #expect(launch.scheduler.startup.completion != nil)
        for _ in 0..<4 { launch.scheduler.fire() }
        #expect(launch.built == ["front", "full", "visible", "covered"], "the covered window builds after startup completes")
        #expect(launch.windows.launchWindows?.isWaiting("covered") == false)
    }

    /// The palette's workspace names and every `controller(for:)` read build nothing; a person's act in the
    /// window (here a focus through the building accessor) builds it at once and takes it out of the queue.
    @Test func readsBuildNothingAndAnActBuildsTheWindowAtOnce() throws {
        let launch = Launch()
        defer { launch.tearDown() }
        launch.restore()
        let covered = WorkspaceModel(WorkspaceSnapshot(id: 7, key: WorkspaceKey(rawValue: "c"), name: "c", screens: []))
        _ = launch.services.shownWorkspaceName(covered)
        #expect(launch.windows.controller(for: "covered") == nil)
        #expect(launch.built == ["front", "full"], "a palette read built a waiting window")

        let controller = try #require(launch.windows.controllerBuildingIfWaiting(for: "covered"))
        #expect(controller.state.id == "covered")
        #expect(launch.windows.launchWindows?.isWaiting("covered") == false, "taken out of the queue")
        launch.scheduler.complete()
        for _ in 0..<8 { launch.scheduler.fire() }
        #expect(launch.windows.controllers.filter { $0.state.id == "covered" }.count == 1, "its post built it a second time")
    }

    /// A waiting window closed before its post is never built.
    @Test func aWaitingWindowClosedBeforeItsPostIsNeverBuilt() {
        let launch = Launch()
        defer { launch.tearDown() }
        launch.restore()
        launch.windows.transition { $0.close("covered", keepsGroup: true) }
        #expect(launch.windows.launchWindows?.isWaiting("covered") == false, "the closed window left the queue")
        launch.scheduler.complete()
        for _ in 0..<8 { launch.scheduler.fire() }
        #expect(!launch.built.contains("covered"), "a window closed before its post was built")
        #expect(launch.built.contains("visible"))
    }

    /// The selected workspace of a waiting window leaves it: the repair waits for the build (its sidebar's drawn
    /// rows), with the membership from before the change, not the membership order with no sidebar.
    @Test func aWaitingWindowsSelectionIsRepairedAtItsBuild() throws {
        let launch = Launch()
        defer { launch.tearDown() }
        launch.restore()
        let before = try #require(launch.windows.registry.value.window("visible")).workspaceIDs
        launch.windows.transition { $0.move(["b2"], to: "front") }
        #expect(launch.windows.states["visible"]?.workspaceID == "b2", "a waiting window keeps its selection until its build")
        #expect(launch.windows.waitingRepairs["visible"] == before, "the repair keeps the membership before the change")
        #expect(!launch.built.contains("visible"), "the repair built the window")

        let controller = try #require(launch.windows.controllerBuildingIfWaiting(for: "visible"))
        #expect(launch.windows.waitingRepairs["visible"] == nil)
        #expect(["b1", "b3"].contains(controller.state.workspaceID ?? ""), "the build repaired the selection to a member")
    }
}
