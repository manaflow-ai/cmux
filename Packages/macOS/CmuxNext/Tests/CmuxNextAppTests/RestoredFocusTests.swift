@testable import CmuxNextApp
import CmuxNextFocus
import Testing

/// After a restart the keyboard goes where the window's record saved it (QA chrome-parity-v2-2-2, bug 1).
///
/// QA's steps: from Home, Ctrl+` (a terminal in the pane beside Home), Cmd+Shift+L example.com (a browser
/// tab in that pane), Cmd-Q, open the app again, type. The typed text landed in Home's Chief message box.
/// The launch window showed the home workspace (its panes, the first one Home's) before it adopted the
/// saved window record; the record's focused pane, the browser pane, then came as `restoredPane` for the
/// workspace the window already showed, and the focus machine dropped it. Home's own message box took
/// the keyboard (its default conversation shown) and the machine kept it: the focus stayed on Home.
@MainActor
struct RestoredFocusTests {
    static let workspace = "home-workspace"

    /// The home workspace as the launch window shows it: Home's page, and the pane beside it with the
    /// terminal and the browser tab (selected).
    static let homeAndBrowser = FocusTopology(workspace: workspace, panes: [
        .init(id: "home-pane", tabs: [.init(id: "home-tab", kind: .page)], selected: "home-tab"),
        .init(id: "right-pane", tabs: [.init(id: "terminal-tab", kind: .terminal), .init(id: "browser-tab", kind: .browser)],
              selected: "browser-tab"),
    ])

    final class Recorder: FocusEffectApplying {
        var effects: [FocusEffect] = []
        func apply(_ effects: [FocusEffect], state: FocusState) { self.effects += effects }
    }

    /// The record comes after the window showed its workspace: its pane gets the keyboard, and the applier is
    /// told to move the responder to the browser page.
    @Test func theSavedPaneOfTheShownWorkspaceGetsTheKeyboard() {
        let focus = FocusCoordinator(), recorder = Recorder()
        focus.applier = recorder
        focus.send(.topology(Self.homeAndBrowser))
        #expect(focus.state.resolved == .page(pane: "home-pane", tab: "home-tab"), "before the record: the first pane")
        recorder.effects.removeAll()
        focus.send(.restoredPane("right-pane", workspace: Self.workspace))
        #expect(focus.state.resolved == .browserPage(pane: "right-pane", tab: "browser-tab"))
        #expect(recorder.effects.contains(.moveResponder(.browserPage(pane: "right-pane", tab: "browser-tab"))))
    }

    /// Home's message box took the keyboard by itself before the record came (a programmatic report, no
    /// person's choice): the saved pane still wins.
    @Test func aViewThatTookTheKeyboardByItselfDoesNotKeepTheRestore() {
        let focus = FocusCoordinator()
        focus.send(.topology(Self.homeAndBrowser))
        focus.send(.responder(.content(pane: "home-pane"), source: .programmatic))
        focus.send(.restoredPane("right-pane", workspace: Self.workspace))
        #expect(focus.state.resolved == .browserPage(pane: "right-pane", tab: "browser-tab"))
    }

    /// What the person chose after the window opened stays: a late record does not take the keyboard back.
    @Test func thePersonsChoiceBeforeTheRecordStays() {
        let focus = FocusCoordinator()
        focus.send(.topology(Self.homeAndBrowser))
        focus.send(.focusPane("home-pane", source: .mouse))
        focus.send(.restoredPane("right-pane", workspace: Self.workspace))
        #expect(focus.state.resolved == .page(pane: "home-pane", tab: "home-tab"))
    }

    /// The record comes first (the usual launch): unchanged, the workspace shows on its saved pane.
    @Test func aRecordBeforeTheWorkspaceShowsStillLandsOnItsPane() {
        let focus = FocusCoordinator()
        focus.send(.restoredPane("right-pane", workspace: Self.workspace))
        focus.send(.topology(Self.homeAndBrowser))
        #expect(focus.state.resolved == .browserPage(pane: "right-pane", tab: "browser-tab"))
    }
}
