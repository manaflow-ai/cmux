import AppKit
@testable import CmuxNextApp
import CmuxNextDaemonService
import CmuxNextDesign
import CmuxNextLayout
import CmuxNextSettings
import CmuxNextTestSupport
import Foundation
import Testing

/// Chief in Side Panel (`home.chiefDock.sidePanel`; David Beyer's feedback, 2026-11-20: an option to open the Chief in
/// a dedicated side panel). On, every window keeps the Chief docked at the Dock Edge beside the workspace it shows,
/// never over Home, and a window that opens later gets it too. Cmd-I still hides it, and the sidebar's Chief row
/// brings it back. Off again, the docked Chief floats and hides; a launch with it off never docks anything
/// (`ChiefNeverDockedByDefaultTests`). A real window: `k0` is Home, `k1`...`k3` ordinary workspaces.
@MainActor @Suite(.serialized, .closesItsWindows)
struct ChiefSidePanelTests {
    typealias Fixture = SidebarMultiViewWindowTests.Fixture

    static func fixture() async throws -> Fixture {
        let (chief, _) = ChiefPanelWindowTests.chiefView()
        return try await ChiefPanelWindowTests.fixture(chief)
    }

    static func show(_ id: String, _ f: Fixture) {
        f.services.windows.show(workspaceID: id, in: f.state, from: .thisWindow)
        f.frame()
    }

    /// The Chief docked at `edge` beside the workspace on the stage, taking its space as a dock does.
    static func expectSidePanel(_ f: Fixture, at edge: DockEdge, _ step: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(f.state.chiefPanel.dockedEdge == edge && f.state.chiefPanel.isOpen,
                "\(step): the Chief is not docked open at \(edge): \(f.state.chiefPanel)", sourceLocation: sourceLocation)
        #expect(f.controller.frameChiefPanelShown, "\(step): no Chief on screen", sourceLocation: sourceLocation)
        let stage = f.controller.content?.contentView.frame.width ?? 0
        #expect(stage > 0 && stage < f.controller.root.contentHost.bounds.width,
                "\(step): the workspace still fills the window, the Chief floats over it", sourceLocation: sourceLocation)
    }

    @Test func turningItOnDocksTheChiefBesideEveryWorkspaceButHome() async throws {
        let f = try await Self.fixture()
        defer { f.close() }
        f.services.chiefSidePanel.follow(on: true, edge: .right, frames: [f.controller])
        f.frame()
        #expect(!f.controller.frameChiefPanelShown, "the side panel shows over Home, which already is the Chief")
        for id in ["k1", "k2", "k3"] {
            Self.show(id, f)
            Self.expectSidePanel(f, at: .right, "showing \(id)")
        }
        Self.show("k0", f)
        #expect(!f.controller.frameChiefPanelShown, "back on Home, the side panel still shows")
    }

    /// Cmd-I hides the side panel; the sidebar's Chief row shows it again beside the same workspace, with the keys.
    @Test func theChiefRowBringsBackASidePanelCmdIHid() async throws {
        let f = try await Self.fixture()
        defer { f.close() }
        #expect(!f.controller.showChiefSidePanel(), "with no side panel the Chief row did not fall back to Home")
        f.services.chiefSidePanel.follow(on: true, edge: .left, frames: [f.controller])
        Self.show("k1", f)
        #expect(f.controller.toggleChiefPanel(), "Cmd-I did nothing")
        f.frame()
        #expect(!f.controller.frameChiefPanelShown, "Cmd-I did not hide the side panel")
        #expect(f.controller.showChiefSidePanel(), "the Chief row did not show the side panel")
        f.frame()
        Self.expectSidePanel(f, at: .left, "after the Chief row")
        #expect(f.controller.content?.workspace.id == "k1", "the Chief row left the workspace")
        Self.show("k0", f)
        #expect(!f.controller.showChiefSidePanel(), "on Home the Chief row did not open the Chief's conversation instead")
    }

    /// A window seen before keeps what the person did (Cmd-I hid it); a window the app had not seen gets the side panel.
    @Test func aNewWindowGetsItAndAHiddenOneStaysHidden() async throws {
        let f = try await Self.fixture()
        defer { f.close() }
        let side = f.services.chiefSidePanel
        side.follow(on: true, edge: .right, frames: [f.controller])
        Self.show("k1", f)
        _ = f.controller.toggleChiefPanel()
        side.windowsDidChange([f.controller])
        f.frame()
        #expect(!f.state.chiefPanel.isOpen, "an unrelated window change undid the person's Cmd-I")
        side.windowsDidChange([]) // the window closed
        side.windowsDidChange([f.controller]) // and one opened with that id
        f.frame()
        Self.expectSidePanel(f, at: .right, "a window the app had not seen")
    }

    @Test func turningItOffFloatsAndHidesTheDockedChief() async throws {
        let f = try await Self.fixture()
        defer { f.close() }
        let side = f.services.chiefSidePanel
        side.follow(on: true, edge: .right, frames: [f.controller])
        Self.show("k1", f)
        Self.expectSidePanel(f, at: .right, "on")
        side.follow(on: false, edge: .right, frames: [f.controller])
        f.frame()
        #expect(f.state.chiefPanel.dockedEdge == nil && !f.state.chiefPanel.isOpen, "off left the Chief docked or open: \(f.state.chiefPanel)")
        #expect(!f.controller.frameChiefPanelShown, "off left a Chief on screen")
    }

    /// cmux#37365: off at launch changes nothing, so a Chief the person docked themselves stays docked.
    @Test func offAtLaunchLeavesAChiefThePersonDocked() async throws {
        let f = try await Self.fixture()
        defer { f.close() }
        Self.show("k1", f)
        f.controller.dockChiefPanel(at: .left)
        f.services.chiefSidePanel.follow(on: false, edge: .right, frames: [f.controller])
        f.frame()
        Self.expectSidePanel(f, at: .left, "the person's own dock, after a launch with the setting off")
    }

    /// The setting itself: cmux.json `home.chiefDock.sidePanel` on with the Dock Edge right reaches the window.
    @Test func theSettingDocksTheChiefAtTheDockEdge() async throws {
        let f = try await Self.fixture()
        defer { f.close() }
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-chief-side-panel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux.json")
        try Data(#"{"home":{"chiefDock":{"sidePanel":true,"edge":"right"}}}"#.utf8).write(to: url)
        let settings = SettingsController(writer: TestSettingsWriter(), registry: f.services.registry, design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        try #require(settings.snapshot.chiefDockSidePanel, "cmux.json's sidePanel did not parse")
        let before = f.services.settings
        f.services.settings = settings
        defer { f.services.settings = before }
        f.services.chiefSidePanel.follow(host: f.services)
        await RapidWorkspaceCreateTests.wait(within: .seconds(5)) { f.state.chiefPanel.isOpen }
        Self.show("k1", f)
        Self.expectSidePanel(f, at: .right, "from the setting")
    }
}
