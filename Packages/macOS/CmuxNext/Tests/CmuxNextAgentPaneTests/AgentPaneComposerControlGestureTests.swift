import AppKit
import CmuxNextTestSupport
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Toggle Plan Mode (Ctrl-Opt-Cmd-P) switches the chat's mode at once, with no click in the page.
/// The app's key router takes the key before the pane's gesture monitor sees it, so the page's
/// `session/set_mode` went with no gesture, the transport refused it, and the chat never entered
/// Plan. The person's own shortcut is that switch's gesture; a posted key, a script or a control
/// that only opens a menu (whose pick in the page is the gesture) grants nothing.
@Suite(.serialized, .closesItsWindows)
@MainActor
struct AgentPaneComposerControlGestureTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// Ctrl-Opt-Cmd-P as if posted by process `source` (0: the HID system, the person's keyboard).
    static func key(source: Int64) throws -> NSEvent {
        let cgEvent = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 35, keyDown: true))
        cgEvent.flags = [.maskControl, .maskAlternate, .maskCommand]
        cgEvent.setIntegerValueField(.eventSourceUnixProcessID, value: source)
        return try #require(NSEvent(cgEvent: cgEvent))
    }

    @Test func thePersonsTogglePlanShortcutIsTheGestureItsModeSwitchSpends() throws {
        let file = try #require(AgentPageTestRoot.page)
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file)))
        defer { view.close() }
        let gestures = view.model.transport.gestures
        let person = try Self.key(source: 0)

        view.showComposerControl(.togglePlan, byPerson: true, event: person)
        #expect(gestures.consume(), "the person's Toggle Plan Mode key must pay for the page's set_mode")
        #expect(!gestures.consume(), "the credit is single-use")

        view.showComposerControl(.togglePlan, byPerson: false, event: person)
        #expect(!gestures.isAvailable, "a run that is not the person's (a script, the control socket) grants nothing")
        view.showComposerControl(.togglePlan, byPerson: true, event: try Self.key(source: Int64(getpid()) + 1))
        #expect(!gestures.isAvailable, "a key another process posted grants nothing")
        view.showComposerControl(.togglePlan, byPerson: true, event: nil)
        #expect(!gestures.isAvailable, "a call outside event dispatch grants nothing")

        for control in AgentComposerControl.allCases where control != .togglePlan {
            view.showComposerControl(control, byPerson: true, event: person)
            #expect(!gestures.isAvailable, "\(control) only opens a control: the person's pick in the page is its gesture")
        }
    }
}
