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
        var tree = SidebarMultiViewWindowTests.Fixture.tree(["k0", "k1"])
        tree.personal.profiles = [ProfileSnapshot(id: .defaultProfile, name: "Personal", index: 0)]
        let fixture = try await SidebarMultiViewWindowTests.Fixture(keys: ["k0", "k1"], tree: tree)
        defer { fixture.close() }

        let store = fixture.services.machines.local.store
        try await Self.until(fixture, title: "Personal — k0")

        try #require(fixture.controller.showTopPage(.page(.stats)), "the stats page did not show")
        fixture.controller.state.page = .page(.stats)
        #expect(fixture.controller.window?.title == "Personal — k0", "the initial top-page native title changed")
        let pageTitle = fixture.controller.root.titlebar.title
        #expect(!pageTitle.isEmpty, "the top page did not set the titlebar title")
        store.profiles = [ProfileModel(ProfileSnapshot(id: .defaultProfile, name: "Work", index: 0))]
        try await Self.until(fixture, title: "Work — k0")
        let workspace = try #require(fixture.services.machines.workspace(id: "k0")?.0)
        workspace.name = "Renamed"
        try await Self.until(fixture, title: "Work — Renamed")
        #expect(fixture.controller.root.titlebar.title == pageTitle,
                "a top-page title was overwritten by the parked workspace title")

        #expect(fixture.controller.leaveTopPage(), "the top page did not leave")
        try await Self.until(fixture, title: "Work — Renamed", chrome: "Renamed")

        fixture.controller.showWorkspace(requested: "k1")
        try await Self.until(fixture, title: "Work — k1", chrome: "k1")
    }

    @Test func distinctProfilesKeepDistinctNativeTitlesForSameWorkspaceName() async throws {
        let personal = ProfileID(rawValue: "personal")
        let work = ProfileID(rawValue: "work")
        var tree = SidebarMultiViewWindowTests.Fixture.tree(["k0", "k1"])
        tree.workspaces[0].name = "Shared"
        tree.workspaces[1].name = "Shared"
        tree.personal.profiles = [
            ProfileSnapshot(id: personal, name: "Personal", index: 0),
            ProfileSnapshot(id: work, name: "Work", index: 1),
        ]
        tree.personal.pins = [
            WorkspacePin(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "k0"), profile: personal),
            WorkspacePin(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "k1"), profile: work),
        ]

        let fixture = try await SidebarMultiViewWindowTests.Fixture(
            keys: ["k0", "k1"], tree: tree, capabilities: ["profiles-v1", "personal-mixed-order-v1"])
        defer { fixture.close() }
        let second = try #require(fixture.services.windows.openWindow(
            id: "window-title-work", workspaces: ["k1"], frame: CGRect(x: 220, y: 180, width: 1200, height: 760)))
        defer {
            second.teardown()
            second.window?.close()
        }

        try await Self.until(fixture.controller, title: "Personal — Shared", second, title: "Work — Shared")
        #expect(fixture.controller.state.profileID == personal)
        #expect(second.state.profileID == work)
        #expect(fixture.controller.window?.title != second.window?.title,
                "two profiles showing the same workspace name shared one native title")
    }

    @Test func restoredTopPageHasNativeTitleBeforeWorkspaceMounts() async throws {
        var tree = SidebarMultiViewWindowTests.Fixture.tree(["k0"])
        tree.personal.profiles = [ProfileSnapshot(id: .defaultProfile, name: "Personal", index: 0)]
        let fixture = try await SidebarMultiViewWindowTests.Fixture(keys: ["k0"], tree: tree)
        defer { fixture.close() }
        let state = WindowState()
        state.workspaceID = "k0"
        state.page = .page(.stats)
        let restored = WindowController(state: state, services: fixture.services, frame: nil)
        defer {
            restored.teardown()
            restored.window?.close()
        }

        #expect(restored.content == nil)
        #expect(restored.window?.title == "Personal — k0")
    }

    private static func until(_ fixture: SidebarMultiViewWindowTests.Fixture, title expected: String,
                              chrome: String? = nil) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while (fixture.controller.window?.title != expected ||
               chrome.map { fixture.controller.root.titlebar.title != $0 } == true), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            fixture.frame()
        }
        let actual = fixture.controller.window?.title ?? "nil"
        try #require(actual == expected, "native title stayed " + actual + ", expected " + expected)
        if let chrome {
            #expect(fixture.controller.root.titlebar.title == chrome,
                    "titlebar stayed " + fixture.controller.root.titlebar.title + ", expected " + chrome)
        }
    }

    private static func until(_ first: WindowController, title firstExpected: String,
                              _ second: WindowController, title secondExpected: String) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while (first.window?.title != firstExpected || second.window?.title != secondExpected), ContinuousClock.now < deadline {
            Self.frame(first)
            Self.frame(second)
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(first.window?.title == firstExpected,
                     "first native title stayed " + (first.window?.title ?? "nil") + ", expected " + firstExpected)
        try #require(second.window?.title == secondExpected,
                     "second native title stayed " + (second.window?.title ?? "nil") + ", expected " + secondExpected)
    }

    private static func frame(_ controller: WindowController) {
        for _ in 0..<3 { RunLoop.main.run(mode: .default, before: Date()) }
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.window?.displayIfNeeded()
    }
}
