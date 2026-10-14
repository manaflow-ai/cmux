@testable import CmuxNextAgentPane
import Foundation
import Testing

/// cx-hnpxh: `tab.open` with a terminal and `run` types the line into a new terminal tab and runs it,
/// so a chat page's script (rendered agent output, say) could run one shell line on this Mac without
/// the person's click. Like `shell.run`, it now needs the person's fresh gesture in the pane (a key or
/// click, ``AgentPaneUserGestures``), which page script cannot make, and uses it once. A terminal
/// opened only to type (`run: false`), an empty terminal and a browser tab run nothing and stay ungated.
@MainActor
struct AgentPaneTabOpenGestureTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// A pane in a tab (a chat, or the New Tab page when `newTab`), with the tabs it opened recorded.
    private final class Rig {
        let model = AgentPaneModel(host: NoHost(), allowsTabConversion: true)
        var opened: [AgentPaneOpenTab] = []

        init(newTab: Bool = false) {
            if newTab { model.becomeNewTab(AgentPaneNewTab(kind: .terminal)) }
            model.onOpenTab = { [weak self] in self?.opened.append($0) }
        }

        func open(_ params: [String: Any], gesture: Bool = false) async -> [String: Any] {
            if gesture { model.transport.gestures.record() }
            return await model.respond(to: AgentPaneRequest(body: ["method": "tab.open", "params": params]))
        }
    }

    private static let run: [String: Any] = ["kind": "terminal", "text": "echo hi", "run": true]

    private static func errorCode(_ reply: [String: Any]) -> String? {
        (reply["error"] as? [String: Any])?["code"] as? String
    }

    @Test func aChatRunsATerminalLineOnlyOnThePersonsGesture() async {
        let rig = Rig()
        let refused = await rig.open(Self.run)
        #expect(refused["ok"] as? Bool != true, "a chat page ran a terminal line without the person's gesture")
        #expect(Self.errorCode(refused) == "transport.gesture_required", "\(refused)")
        #expect(rig.opened.isEmpty, "a terminal opened without the person's gesture: \(rig.opened)")

        // The page leaves `run` out: a terminal runs its text by default.
        _ = await rig.open(["kind": "terminal", "text": "echo hi"])
        #expect(rig.opened.isEmpty, "a terminal opened without `run` ran its line without a gesture")

        let allowed = await rig.open(Self.run, gesture: true)
        #expect(allowed["ok"] as? Bool == true, "\(allowed)")
        #expect(rig.opened == [AgentPaneOpenTab(kind: .terminal, text: "echo hi", run: true)])

        // One gesture runs one line.
        _ = await rig.open(Self.run)
        #expect(rig.opened.count == 1, "one gesture ran two lines")
    }

    /// The New Tab page's Return is the person's key in the page: its run is gated the same way.
    @Test func theNewTabPageRunsATerminalLineOnlyOnThePersonsGesture() async {
        let rig = Rig(newTab: true)
        #expect(Self.errorCode(await rig.open(Self.run)) == "transport.gesture_required")
        #expect(rig.opened.isEmpty)
        #expect(await rig.open(Self.run, gesture: true)["ok"] as? Bool == true)
        #expect(rig.opened.count == 1)
    }

    /// Opens that run nothing need no gesture and leave the person's gesture for a later run.
    @Test func opensThatRunNothingStayUngated() async {
        let rig = Rig()
        rig.model.transport.gestures.record()
        #expect(await rig.open(["kind": "terminal", "text": "make test", "run": false])["ok"] as? Bool == true)
        #expect(await rig.open(["kind": "terminal", "text": "", "run": true])["ok"] as? Bool == true)
        #expect(await rig.open(["kind": "browser", "text": "example.com"])["ok"] as? Bool == true)
        #expect(rig.opened.count == 3, "\(rig.opened)")
        #expect(rig.model.transport.gestures.isAvailable, "an open that runs nothing used the person's gesture")
    }
}
