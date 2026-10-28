import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextFeed
import CmuxNextWakeups
import Foundation
import Testing

/// The GitHub poll follows the feed's surfaces: each feed host the app makes (here the
/// right sidebar's Feed section) counts in `FeedService.surfaces` through its own node, which sits under
/// its window's node while it is in the window and leaves it with the host.
@MainActor @Suite(.serialized)
struct FeedSurfaceVisibilityTests {
    @Test func theSidebarFeedSectionCountsAsAFeedSurfaceUnderItsWindow() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let suite = "cmux-feed-surface-visibility-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        services.rightSidebarDefaults = defaults
        services.windows.ordersWindowsIn = false
        AppActions.bind(services)
        let controller = try #require(services.windows.openWindow(workspaces: ["fsv-workspace"]))
        defer {
            for controller in services.windows.controllers { controller.window?.close() }
            defaults.removePersistentDomain(forName: suite)
        }

        let surfaces = services.feed.surfaces
        let before = surfaces.trackedCount
        #expect(services.registry.perform("switchRightSidebarToFeed", invocation: ActionInvocation(origin: .cli)))
        let feed = try #require(controller.root.rightPanel?.shownSection as? FeedHostView)
        #expect(surfaces.trackedCount == before + 1, "the sidebar's Feed section is not a feed surface")
        #expect(feed.visibilityNode.parent === controller.visibility, "the Feed section's node is not under its window's")

        feed.removeFromSuperview()
        #expect(feed.visibilityNode.parent !== controller.visibility, "a Feed section out of the window still follows it")
        #expect(!feed.visibilityNode.isVisible)
    }
}
