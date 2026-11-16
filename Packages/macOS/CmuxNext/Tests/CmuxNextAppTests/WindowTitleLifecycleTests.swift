import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextTestSupport
import Foundation
import Testing

/// The native title remains live while a top page covers the workspace. The workspace stays mounted
/// under the page, so its title observation must stay mounted too (the old cancellation in
/// `parkContentForPage()` left Dock and Cmd-` with the old space name).
@MainActor @Suite(.serialized, .closesItsWindows)
struct WindowTitleLifecycleTests {
    @Test func profileRenameWhileTopPageIsShownUpdatesNativeWindowTitle() async throws {
        var tree = SidebarMultiViewWindowTests.Fixture.tree(["k0"])
        tree.personal.profiles = [ProfileSnapshot(id: .defaultProfile, name: "Personal", index: 0)]
        let fixture = try await SidebarMultiViewWindowTests.Fixture(keys: ["k0"], tree: tree)
        defer { fixture.close() }

        let store = fixture.services.machines.local.store
        try await Self.until(fixture, title: "Personal — k0")

        try #require(fixture.controller.showTopPage(.page(.stats)), "the stats page did not show")
        store.profiles = [ProfileModel(ProfileSnapshot(id: .defaultProfile, name: "Work", index: 0))]
        try await Self.until(fixture, title: "Work — k0")
    }

    private static func until(_ fixture: SidebarMultiViewWindowTests.Fixture, title expected: String) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while fixture.controller.window?.title != expected, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            fixture.frame()
        }
        let actual = fixture.controller.window?.title ?? "nil"
        try #require(actual == expected, "native title stayed " + actual + ", expected " + expected)
    }
}
