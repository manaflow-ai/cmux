import AppKit
import Foundation
import Testing
import WebKit
@testable import CmuxNextAgentPane
import CmuxNextPagesTestSupport

/// An agent page cannot take the keyboard by itself (cx-3hw0i.2, `AgentPaneView.refusesSelfFocus`).
/// A pane keeps a tab it does not show parked in place, hidden (PaneContentView+Parking): a chat or
/// New Tab page behind the shown tab of the focused pane. Its own `element.focus()` (the composer
/// mounting as a New Tab ask turns into the chat, a reconnect) makes WebKit ask the window to make
/// its web view first responder. The focus model files that as the same pane's content, so nothing
/// re-applies it: typing went into the hidden page until the next pane or tab switch.
@Suite(.serialized)
@MainActor
struct AgentPaneSelfFocusTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// An agent page inside `host`, as a pane's content host holds it.
    private func page(in host: NSView) throws -> (AgentPaneView, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "self-focus-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "index.html")
        try Data("<html><body></body></html>".utf8).write(to: file)
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file), errors: DroppedErrors()))
        host.addSubview(view)
        return (view, directory)
    }

    private func refuses(_ view: AgentPaneView, inInputEvent: Bool = false, focusModelApplies: Bool = false,
                         focusedPane: String? = "pane-a", shownIn pane: String? = "pane-a") -> Bool {
        AgentPaneView.refusesSelfFocus(view.webView, inInputEvent: inInputEvent, focusModelApplies: focusModelApplies,
                                       focusedPane: { focusedPane }, pane: { _ in pane })
    }

    @Test func aHiddenPageInTheFocusedPaneCannotTakeTheKeyboard() throws {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let (view, directory) = try page(in: host)
        defer { try? FileManager.default.removeItem(at: directory) }
        view.isHidden = true
        #expect(refuses(view), "a page parked hidden behind the focused pane's shown tab took the keyboard")
        #expect(refuses(view, shownIn: nil), "a hidden page no pane shows took the keyboard")
        #expect(refuses(view, focusedPane: nil), "a hidden page took the keyboard while no pane had focus")
    }

    @Test func aPageUnderAHiddenAncestorCannotTakeTheKeyboard() throws {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let (view, directory) = try page(in: host)
        defer { try? FileManager.default.removeItem(at: directory) }
        host.isHidden = true
        #expect(refuses(view), "a page inside a hidden view took the keyboard")
    }

    @Test func theShownPageAndTheUsersOwnMovesStillGiveTheKeyboard() throws {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let (view, directory) = try page(in: host)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(!refuses(view), "the focused pane's shown page could not take the keyboard")
        #expect(refuses(view, shownIn: "pane-b"), "a page in another pane took the keyboard by itself")
        view.isHidden = true
        #expect(!refuses(view, inInputEvent: true), "a click or key into the page was refused")
        #expect(!refuses(view, focusModelApplies: true), "the focus model's own move was refused")
    }
}
