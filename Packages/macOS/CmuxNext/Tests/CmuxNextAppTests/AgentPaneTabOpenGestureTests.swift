@testable import CmuxNextAgentPane
import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextTestSupport
import Foundation
import Testing

/// cx-hnpxh: `tab.open` with a terminal and `run` types the line into a new terminal tab and runs it,
/// so a chat page's script (rendered agent output, say) could run one shell line on this Mac without
/// the person's click. Like `shell.run`, it now needs the person's fresh gesture in the pane (a key or
/// click, ``AgentPaneUserGestures``), which page script cannot make, and uses it once. A terminal
/// opened only to type printable text (`run: false`), an empty terminal and a browser tab run nothing
/// and stay ungated; typed text with a control key (`run: false`, `tab.typeAhead`) is a run.
@Suite(.serialized, .closesItsWindows)
@MainActor
struct AgentPaneTabOpenGestureTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// A pane in a tab (a chat, or the New Tab page when `newTab`), with the tabs it opened recorded.
    private final class Rig {
        let model = AgentPaneModel(host: NoHost(), allowsTabConversion: true)
        var opened: [AgentPaneOpenTab] = []
        var typedAhead: [String] = []

        init(newTab: Bool = false) {
            if newTab { model.becomeNewTab(AgentPaneNewTab(kind: .terminal)) }
            model.onOpenTab = { [weak self] in self?.opened.append($0) }
            model.onTypeAhead = { [weak self] in self?.typedAhead.append($0) }
        }

        func typeAhead(_ text: String) async -> [String: Any] {
            await model.respond(to: AgentPaneRequest(body: ["method": "tab.typeAhead", "params": ["text": text]]))
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

    /// `run: false` types its text at the new terminal's prompt as raw keys (no bracketed paste), so a
    /// newline, a carriage return or Ctrl-O in it runs the line all the same. Text with a control
    /// character other than DEL (the type-ahead's erase) is a run: it needs the person's gesture.
    @Test func typedTextWithAControlKeyRunsOnlyOnThePersonsGesture() async {
        let rig = Rig()
        for text in ["echo hi\n", "echo hi\r", "\u{0f}", "id\u{1b}", "id\u{85}"] {
            let refused = await rig.open(["kind": "terminal", "text": text, "run": false])
            #expect(Self.errorCode(refused) == "transport.gesture_required", "run: false typed \(text.debugDescription) without a gesture: \(refused)")
        }
        #expect(rig.opened.isEmpty, "a terminal typed a control key without the person's gesture: \(rig.opened)")

        #expect(await rig.open(["kind": "terminal", "text": "echo hi\n", "run": false], gesture: true)["ok"] as? Bool == true)
        #expect(rig.opened == [AgentPaneOpenTab(kind: .terminal, text: "echo hi\n", run: false)])
        #expect(!rig.model.transport.gestures.isAvailable, "one gesture typed control keys twice")

        // Printable text and DEL only type: still no gesture needed.
        #expect(await rig.open(["kind": "terminal", "text": "echo hi \u{7f}é", "run": false])["ok"] as? Bool == true)
        #expect(rig.opened.count == 2, "\(rig.opened)")
    }

    /// `tab.typeAhead` text reaches the terminal the page turns into as the same raw keys: a control
    /// key in it needs the person's gesture too, and the text never reaches the terminal without one.
    @Test func typeAheadWithAControlKeyNeedsThePersonsGesture() async {
        let rig = Rig(newTab: true)
        let refused = await rig.typeAhead("id\r")
        #expect(Self.errorCode(refused) == "transport.gesture_required", "tab.typeAhead typed a Return without a gesture: \(refused)")
        #expect(await rig.typeAhead("\u{0f}")["ok"] as? Bool != true)
        #expect(rig.typedAhead.isEmpty, "type-ahead with a control key reached the terminal: \(rig.typedAhead)")

        #expect(await rig.typeAhead("ls -la\u{7f}")["ok"] as? Bool == true, "printable type-ahead was refused")
        rig.model.transport.gestures.record()
        #expect(await rig.typeAhead("id\r")["ok"] as? Bool == true)
        #expect(rig.typedAhead == ["ls -la\u{7f}", "id\r"], "\(rig.typedAhead)")
    }

    /// A Return key as process `source` sent it (the HID system's events carry source pid 0).
    private static func returnKey(source: Int64) throws -> NSEvent {
        let cgEvent = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: true))
        cgEvent.setIntegerValueField(.eventSourceUnixProcessID, value: source)
        return try #require(NSEvent(cgEvent: cgEvent))
    }

    /// Keys typed before the New Tab field was ready wait in the router's hold, and the hold
    /// replays them past the pane's gesture monitor. The replay judges the person's held Return in
    /// the pane, so the line it submits still runs; a key another process posted grants nothing.
    @Test func aHeldReturnReplayedIntoThePageIsThePersonsGesture() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "held-return-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "index.html")
        try Data("<html><body><input></body></html>".utf8).write(to: file)
        let model = AgentPaneModel(host: NoHost(), allowsTabConversion: true)
        model.becomeNewTab(AgentPaneNewTab(kind: .terminal))
        let view = try #require(AgentPaneView(model: model, source: .bundled(file)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        window.contentView = view
        try #require(window.makeFirstResponder(view.webView), "the page's field could not take the keyboard")
        let router = KeyRouter(registry: ActionRegistry.standard())

        let posted = try Self.returnKey(source: Int64(getpid()) + 1)
        NewTabInputCoordinator.replay(posted, held: posted, in: window, router: router)
        #expect(!model.transport.gestures.isAvailable, "a held key another process posted counted as the person's")

        let person = try Self.returnKey(source: 0)
        NewTabInputCoordinator.replay(person, held: person, in: window, router: router)
        #expect(model.transport.gestures.isAvailable, "the person's held Return left no gesture in the page")
    }
}
