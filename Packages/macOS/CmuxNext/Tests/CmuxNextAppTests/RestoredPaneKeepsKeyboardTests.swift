import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextFocus
import Foundation
import Testing

/// QUIT P0 second fault (STATUS 2994): after a Cmd-Q and a reopen, the first line typed into the restored, focused
/// terminal was lost in 3 of 4 fleet rounds. At launch the restored pane's surface is not presented yet, so the
/// focus applier takes the keyboard off the panes and waits for `contentPresented`. AppKit then orders the window
/// front with the window as first responder and picks the first view that accepts it on its own: the sidebar list.
/// The window reported that as a programmatic responder change, the focus model took it as the person's choice, and
/// the later `contentPresented` re-applied the SIDEBAR target, so the keys went to the sidebar list while every focus
/// check said "consistent". A responder AppKit picks with no input event must not move the focus model's target off
/// the focused pane; only the person (a click, a key) or cmux's own intent (`focusTarget`) moves it to the sidebar.
@MainActor @Suite(.serialized) struct RestoredPaneKeepsKeyboardTests {
    private static func topology(_ workspace: String, panes: [String]) -> FocusTopology {
        FocusTopology(workspace: workspace, panes: panes.map { pane in
            FocusTopology.Pane(id: pane, tabs: [.init(id: "\(pane)-tab", kind: .terminal)], selected: "\(pane)-tab")
        })
    }

    private static func restoredState() throws -> WindowState {
        let saved = #"{"id":"restored-keys","workspace_key":"ws","focused_pane":"right","focused_panes":{"ws":"right"}}"#
        let state = WindowState(record: try JSONDecoder().decode(WindowRecord.self, from: Data(saved.utf8)))
        state.focus.send(.topology(Self.topology("ws", panes: ["main", "right"])))
        return state
    }

    @Test func aResponderAppKitPicksAtLaunchDoesNotTakeTheRestoredPanesKeyboard() throws {
        let state = try Self.restoredState()
        #expect(state.focus.state.pane == "right")
        #expect(state.focus.state.target == .content)
        let before = state.focus.state
        // AppKit chose the sidebar list as the window came forward (no input event, no cmux call).
        state.focus.send(.responder(.sidebar, source: .programmatic))
        #expect(state.focus.state.pane == "right", "the restored pane lost focus")
        #expect(state.focus.state.target == .content,
                "an unrequested sidebar responder became the focus target: \(state.focus.state.target)")
        #expect(InputInvariants.transition(from: before, .responder(.sidebar, source: .programmatic), to: state.focus.state).isEmpty)
    }

    @Test func theFocusCheckerFlagsAnUnrequestedMoveToTheSidebar() throws {
        let state = try Self.restoredState()
        let onContent = state.focus.state
        // The state a move to the sidebar makes (here through an explicit target, to get the shape).
        state.focus.send(.focusTarget(.sidebar(keyboard: false), source: .programmatic))
        let onSidebar = state.focus.state
        #expect(onSidebar.target == .sidebar(keyboard: false))
        let violations = InputInvariants.transition(from: onContent, .responder(.sidebar, source: .programmatic), to: onSidebar)
        #expect(violations.contains { $0.invariant == .noUnrequestedResponderMove },
                "the checker said nothing about an unrequested move off the focused pane: \(violations)")
    }

    @Test(arguments: [FocusEvent.Source.mouse, .keyboard])
    func aPersonStillPutsTheKeyboardOnTheSidebar(source: FocusEvent.Source) throws {
        let state = try Self.restoredState()
        state.focus.send(.responder(.sidebar, source: source))
        #expect(state.focus.state.target == .sidebar(keyboard: source == .keyboard))
    }

    @Test func focusSidebarAndTheEndOfARenameKeepTheSidebar() throws {
        let state = try Self.restoredState()
        // Focus Sidebar (its action states the target, then AppKit reports the list).
        state.focus.send(.focusTarget(.sidebar(keyboard: true), source: .keyboard))
        state.focus.send(.responder(.sidebar, source: .programmatic))
        #expect(state.focus.state.target == .sidebar(keyboard: true))
        // An inline rename ends and gives the list the keyboard back.
        state.focus.send(.focusTarget(.sidebarField, source: .mouse))
        state.focus.send(.responder(.sidebar, source: .programmatic))
        #expect(state.focus.state.target.isSidebar, "the list lost the keyboard after a rename: \(state.focus.state.target)")
    }

    // MARK: The window (a display worker: CMUX_TEST_REQUIRE_GUI=1 fails a skip)

    static func hasDisplay() -> Bool { !NSScreen.screens.isEmpty }

    /// The launch order made deterministic: the window comes forward while the restored pane's surface is not
    /// presented yet (no content view exists in this window at all), so AppKit picks a key view itself.
    @Test(.enabled("needs a display: AppKit picks the first responder only for an ordered-in key window") { await Self.hasDisplay() })
    func aWindowOrderedFrontBeforeItsRestoredContentKeepsTheFocusOnThatPane() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let state = try Self.restoredState()
        let controller = WindowController(state: state, services: services, frame: NSRect(x: 200, y: 200, width: 900, height: 600))
        defer {
            controller.teardown()
            controller.window?.close()
        }
        let window = try #require(controller.window)
        #expect(controller.focus.state.pane == "right")
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        let picked = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        #expect(controller.focus.state.target == .content,
                "AppKit's own pick (\(picked)) became the focus target \(controller.focus.state.target)")
        #expect(controller.focus.state.pane == "right")
    }
}

private extension FocusState.Target {
    var isSidebar: Bool {
        switch self {
        case .sidebar, .sidebarField: true
        default: false
        }
    }
}
