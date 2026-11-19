import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
import CmuxNextTerminal
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// `PaneCommitMotionTests`, the app's own write of a pane's wait for its terminal.
///
/// A split's new terminal pane shows no view in the frame of its key, and the app says on the pane's area that a
/// terminal comes (`ThemeCoordinator.applyPaneBackground`, which the pane's controller calls at each change of its
/// content). The pane rides its move from that write on, in each window: over a window's picture a terminal paints no
/// ground of its own, so the area waits with no ground there. This row makes the app's pane with its controller and
/// calls that write; it makes no terminal and presses no key.
extension PaneCommitMotionTests {
    nonisolated static let waitWrites = ["over a picture", "in a see-through window with no picture", "with a terminal colour of the user"]

    private static func waitTree() -> DaemonTree {
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(PaneID(rawValue: 1)), panes: [pane])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w1", screens: [screen])])
    }

    private static func waitDaemon() throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"pane-waits-for-its-terminal-test","generation":"g1"}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    /// The app's pane with no view in its content area. Over a picture background (the pane's scope has a picture and
    /// a tint of 0.85) and in a see-through window with no picture (its scope's theme has an opacity of 0.6) a
    /// terminal's ground is nil; with a terminal colour of the user it is that colour. After the app's write
    /// `a terminal comes` the pane rides in each. A later paint of the pane's background that says nothing of the
    /// wait keeps it, and the write `no terminal comes` ends it.
    @Test(arguments: waitWrites)
    func aPaneThatWaitsForItsTerminalRidesByTheAppsOwnWrite(_ look: String) throws {
        _ = NSApplication.shared
        let seeThrough = look != "with a terminal colour of the user"
        let saved = ReduceTransparency.shared.override
        ReduceTransparency.shared.override = false
        defer { ReduceTransparency.shared.override = saved }
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        store.connectionState = .connected(try Self.waitDaemon())
        store.apply(snapshot: Self.waitTree())
        let model = try #require(store.workspaces.first?.screens.first?.panes.first)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        let state = WindowState(record: record)
        let pane = PaneController(pane: model, daemon: services.daemon, layoutPaneID: LayoutPaneID(model.id), services: services, state: state)
        defer { pane.teardown() }
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        pane.view.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        window.contentView = pane.view
        window.orderFrontRegardless()
        switch look {
        case "over a picture":
            pane.view.paneScope.pinBackdrop(.selection(.art(.dahlDresdenMoonlight)))
            pane.view.paneScope.pinBackdropTint(0.85)
        case "in a see-through window with no picture":
            let spec = try #require(ThemeSpec("Stress Purple"), "SETUP: the theme's name is no theme spec")
            let input = ThemeInput(background: ThemeRGB(hex: 0x2B1650), foreground: ThemeRGB(hex: 0xF4E3FF), backgroundOpacity: 0.6)
            pane.view.paneScope.setOverride(spec, input: input, animated: false)
        default:
            pane.view.paneScope.setSurfaceBackgrounds(SurfaceBackgrounds(overrides: [.terminal: SurfaceBackground(color: ThemeRGB(hex: 0x00FFFF), opacity: 1)]))
        }
        pane.view.layoutSubtreeIfNeeded()
        let area = pane.view.contentHost
        let ground = TerminalHostView.ground(theme: nil, in: area)
        try #require((ground == nil) == seeThrough, "SETUP: \(look) a terminal's ground is \(String(describing: ground))")
        let room = area.bounds
        try #require(room.width >= 1 && room.height >= 1 && pane.view.paneCommitMotionTop == nil,
                     "SETUP: the pane's area has the size \(room.size) and a view on top: the test does not reach the case")

        services.themes.applyPaneBackground(pane, waitsForTerminal: false)
        #expect(!pane.view.paneRidesCommitMotion, "a pane whose area shows no view and waits for no terminal rides")
        services.themes.applyPaneBackground(pane, waitsForTerminal: true)
        #expect(pane.view.paneRidesCommitMotion,
                "\(look) the app wrote that the pane waits for its terminal, and the pane does not ride: its split shows in one frame")
        services.themes.applyPaneBackground(pane)
        #expect(pane.view.paneRidesCommitMotion, "\(look) a later paint of the pane's background ended the wait for the terminal")
        services.themes.applyPaneBackground(pane, waitsForTerminal: false)
        #expect(!pane.view.paneRidesCommitMotion, "\(look) the app wrote that no terminal comes, and the pane still rides")
    }
}
