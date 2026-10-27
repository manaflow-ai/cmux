import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextFeatures
@testable import CmuxNextLayout
import CmuxNextWakeups
import Foundation
import Testing

/// p06-scheduler-038 through the real path: the daemon store changes the tree in a cause's scope
/// (as its drain does per envelope), the workspace's observation applies it on its hop, and
/// `LayoutChangeCauses` tells the layout who made the change, so an agent's burst of splits starts
/// no spring and a person's split springs.
@MainActor struct AutomationBurstApplyTests {
    private static func tree(panes: Int) -> DaemonTree {
        let snapshots = (1...panes).map { id in
            PaneSnapshot(id: PaneID(rawValue: UInt64(id)), tabs: [TabSnapshot(surface: SurfaceID(rawValue: UInt64(id)), title: "~")])
        }
        let layout = snapshots.dropFirst().reduce(LayoutNode.leaf(snapshots[0].id)) { node, pane in
            .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: node, b: .leaf(pane.id))
        }
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: layout, panes: snapshots)
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w1", screens: [screen])])
    }

    private static func connected() throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"automation-burst-apply-test","generation":"g1"}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    /// Lets the workspace's observation hop run.
    private static func settle() async {
        for _ in 0..<100 { await Task.yield() }
    }

    /// A one-pane workspace shown in a borderless window, laid out, with springs allowed and the
    /// test as the display clock and the burst clock.
    @MainActor
    final class Shown {
        final class Clock {
            var now: CFTimeInterval = 100
        }

        let services: AppServices
        let state: WindowState
        let window: NSWindow
        let content: WorkspaceContentController
        let clock = Clock()

        init(burstsOn: Bool) throws {
            _ = NSApplication.shared
            services = AppServices(environment: AppEnvironment.current([:]))
            services.features = FeatureList(registry: FeatureRegistry(), channel: .dev,
                                            overrides: FeatureOverrides(environmentEnabled: burstsOn ? ["automationBurstSnap"] : []))
            let store = services.daemon.store
            store.connectionState = .connected(try AutomationBurstApplyTests.connected())
            store.apply(snapshot: AutomationBurstApplyTests.tree(panes: 1))
            let workspace = try #require(store.workspaces.first)
            let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
            state = WindowState(record: record)
            window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 1200, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            content = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: state)
            content.contentView.frame = NSRect(x: 0, y: 0, width: 1200, height: 700)
            window.contentView = content.contentView
            window.orderFrontRegardless()
            content.contentView.layoutSubtreeIfNeeded()
            content.layoutView.context.reduceMotionOverride = false
            content.layoutView.driver.isManual = true
            content.layoutView.burstClock = { [clock] in clock.now }
        }

        /// The store takes a tree of `panes` panes in `cause`'s scope; the observation applies it.
        func split(into panes: Int, cause: ObservationCause) async {
            services.mainWork.causes.withCause(cause) { services.daemon.store.apply(snapshot: AutomationBurstApplyTests.tree(panes: panes)) }
            await AutomationBurstApplyTests.settle()
        }

        var screen: ScreenContentView? { content.layoutView.screenViews.values.first }

        func close() {
            withExtendedLifetime((services, state)) {
                content.teardown()
                window.close()
            }
        }
    }

    @Test func anAgentsCoalescedSplitsStartNoSpringAndLayOutOnce() async throws {
        let shown = try Shown(burstsOn: true)
        defer { shown.close() }
        let screen = try #require(shown.screen)
        let passes = screen.reconcilePasses
        await shown.split(into: 6, cause: .automation)
        #expect(screen.paneFrames.count == 6, "the observation did not apply the store's tree")
        #expect(!screen.hasMotion, "a spring started")
        #expect(screen.reconcilePasses - passes == 1, "\(screen.reconcilePasses - passes) layout passes")
        #expect(shown.content.layoutView.automationBurstSnaps == 1)
    }

    @Test func anAgentsSplitsOnConsecutiveFramesSpringOnce() async throws {
        let shown = try Shown(burstsOn: true)
        defer { shown.close() }
        let screen = try #require(shown.screen)
        await shown.split(into: 2, cause: .automation)
        #expect(screen.hasMotion, "the burst's first split springs")
        for panes in 3...6 {
            shown.clock.now += 1.0 / 120
            await shown.split(into: panes, cause: .automation)
            #expect(!screen.hasMotion, "split \(panes - 1) of the burst started a spring")
        }
        #expect(shown.content.layoutView.automationBurstSnaps == 4)
    }

    @Test func aPersonsSplitSprings() async throws {
        let shown = try Shown(burstsOn: true)
        defer { shown.close() }
        await shown.split(into: 3, cause: .person)
        #expect(try #require(shown.screen).hasMotion)
        #expect(shown.content.layoutView.automationBurstSnaps == 0)
    }

    @Test func burstsOffAnAgentsSplitsSpringAsBefore() async throws {
        let shown = try Shown(burstsOn: false)
        defer { shown.close() }
        await shown.split(into: 6, cause: .automation)
        #expect(try #require(shown.screen).hasMotion)
        #expect(shown.content.layoutView.automationBurstSnaps == 0)
    }
}
