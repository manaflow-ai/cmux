@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextFocus
import Foundation
import Testing

/// After a relaunch the keyboard goes where the window's record saved it (QA chrome-parity-v2-2-2, bug 1).
///
/// QA's steps: from Home, Ctrl+` (a terminal in the pane beside Home), Cmd+Shift+L example.com (a browser
/// tab in that pane), Cmd-Q, open the app again, type. The typed text landed in Home's Chief message box.
/// The launch window showed the home workspace (its panes, the first one Home's) before it adopted the
/// saved window record; the record's focused pane, the browser pane, then came as `restoredPane` for the
/// workspace the window already showed, and the focus rule (cmux-focus-core) dropped it. The focus stayed
/// on Home's pane, and Home's own message box took the keyboard.
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

    static let browser = FocusState.Resolved.browserPage(pane: "right-pane", tab: "browser-tab")

    final class Recorder: FocusEffectApplying {
        var effects: [FocusEffect] = []
        func apply(_ effects: [FocusEffect], state: FocusState) { self.effects += effects }
    }

    /// The saved record of the relaunched window: the home workspace, its browser pane focused.
    static func record() throws -> WindowRecord {
        let saved = #"{"id":"w1","workspace_key":"home-workspace","focused_pane":"right-pane"}"#
        return try JSONDecoder().decode(WindowRecord.self, from: Data(saved.utf8))
    }

    /// The launch window showing the home workspace before it adopts the record, as at a relaunch.
    static func launchWindowShowingHome() -> WindowState {
        let state = WindowState(id: "launch", workspaceID: workspace)
        state.focus.send(.topology(homeAndBrowser))
        return state
    }

    /// The record comes after the window showed its workspace (`WindowState.adopt`, the relaunch path): its
    /// pane gets the keyboard, and the applier is told to move the responder to the browser page.
    @Test func theSavedPaneOfTheShownWorkspaceGetsTheKeyboard() throws {
        let state = Self.launchWindowShowingHome(), recorder = Recorder()
        state.focus.applier = recorder
        #expect(state.focus.state.resolved == .page(pane: "home-pane", tab: "home-tab"), "before the record: the first pane")
        state.adopt(try Self.record())
        #expect(state.focus.state.resolved == Self.browser, "the restored keyboard target")
        #expect(recorder.effects.contains(.moveResponder(Self.browser)))
    }

    /// Home's message box took the keyboard by itself before the record came (a programmatic report, no
    /// person's choice): the saved pane still wins.
    @Test func aViewThatTookTheKeyboardByItselfDoesNotKeepTheRestore() throws {
        let state = Self.launchWindowShowingHome()
        state.focus.send(.responder(.content(pane: "home-pane"), source: .programmatic))
        state.adopt(try Self.record())
        #expect(state.focus.state.resolved == Self.browser)
    }

    /// What the person chose after the window opened stays: a late record does not take the keyboard back.
    @Test func thePersonsChoiceBeforeTheRecordStays() throws {
        let state = Self.launchWindowShowingHome()
        state.focus.send(.focusPane("home-pane", source: .mouse))
        state.adopt(try Self.record())
        #expect(state.focus.state.resolved == .page(pane: "home-pane", tab: "home-tab"))
    }

    /// The record comes first (the usual launch): unchanged, the workspace shows on its saved pane.
    @Test func aRecordBeforeTheWorkspaceShowsStillLandsOnItsPane() throws {
        let state = WindowState(record: try Self.record())
        state.focus.send(.topology(Self.homeAndBrowser))
        #expect(state.focus.state.resolved == Self.browser)
    }

    /// Home gives its message box the keyboard by itself (its default conversation shown, the box installed)
    /// only while the focus model keeps the keyboard in Home's pane. With the browser page beside it focused,
    /// the window itself is first responder (a Chromium page keeps the keys in its own window), which is not
    /// "nothing has the keyboard": Home took it and the model followed (QA v2.2.2 bug 1).
    @Test func homeTakesTheKeyboardUnaskedOnlyWhileTheModelKeepsItInHomesPane() {
        let focus = FocusCoordinator()
        focus.send(.topology(Self.homeAndBrowser))
        #expect(focus.state.keepsKeyboard(inContentOf: "home-pane"))
        focus.send(.focusPane("right-pane", source: .mouse))
        #expect(!focus.state.keepsKeyboard(inContentOf: "home-pane"), "the browser page has the keyboard")
        #expect(focus.state.keepsKeyboard(inContentOf: "right-pane"))
        focus.send(.focusTarget(.addressBar, source: .keyboard))
        #expect(!focus.state.keepsKeyboard(inContentOf: "right-pane"), "the address bar is not the pane's content")
        focus.send(.overlayOpened(.palette))
        focus.send(.focusPane("home-pane", source: .mouse))
        #expect(!focus.state.keepsKeyboard(inContentOf: "home-pane"), "the palette over the window has the keyboard")
    }
}
