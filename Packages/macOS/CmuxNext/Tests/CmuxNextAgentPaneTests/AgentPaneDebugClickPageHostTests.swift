#if DEBUG
import AppKit
import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextSettings
import CmuxNextTestSupport
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// `debug.agent_pane click` on a chat shown by the shared page host (`agent.pageHost`): the
/// element is found in the page the chat shows, not in the pane's own unused WebKit view, which
/// holds no document (a capture slot answered "no visible element matches" for every selector,
/// even `textarea`, while `chat_state` worked on the same pane).
@Suite(.closesItsWindows, .serialized)
@MainActor
struct AgentPaneDebugClickPageHostTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @Test func clickFindsAnElementOfThePageTheChatShows() async throws {
        let file = try #require(AgentPageTestRoot.page)
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file), pageHost: true, testRoot: true,
                                              chromium: nil))
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        // The page loads in the page host.
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let ready = try? await view.callPageScript("return !!document.querySelector('textarea');") as? Bool
            if ready == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        let field = await view.debugLocate(selector: "textarea", text: "")
        #expect(field["error"] == nil, "\(field)")
        #expect(field["tag"] as? String == "textarea")
        #expect((field["x"] as? Double).map { abs($0 - 108) < 2 } == true, "\(field)")

        let remove = await view.debugLocate(selector: "", text: "Remove red.png")
        #expect(remove["tag"] as? String == "button", "\(remove)")
        #expect((remove["x"] as? Double).map { abs($0 - 308) < 2 } == true, "\(remove)")

        let none = await view.debugLocate(selector: ".missing", text: "")
        #expect(none["error"] as? String == "no visible element matches")
    }
    /// The default: the chat shows in Chromium and the pane's own WebKit view is hidden and empty. The
    /// element is found by a script in the Chromium page and pressed with DevTools input there.
    @Test func clickFindsAndPressesAnElementOfAChromiumChat() async throws {
        let file = try #require(AgentPageTestRoot.page)
        let hosting = FakeChromiumHosting()
        // The click verb's locate script finds a button at 308,18.
        hosting.onMade = { page in
            page.answer = { method, params in
                guard method == "Runtime.evaluate",
                      (params["expression"] as? String)?.contains("no visible element matches") == true else { return nil }
                return #"{"result":{"type":"string","value":"{\"x\":308,\"y\":18,\"tag\":\"button\"}"}}"#
            }
        }
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file), pageHost: true, testRoot: true,
                                              chromium: hosting))
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let deadline = Date().addingTimeInterval(5)
        while !view.debugShowsChromium, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(view.debugShowsChromium)

        let remove = await view.debugLocate(selector: "", text: "Remove red.png")
        #expect(remove["tag"] as? String == "button", "\(remove)")
        #expect(remove["x"] as? Double == 308, "\(remove)")
        #expect(await view.debugPress(x: 308, y: 18))
        let presses = hosting.made.last?.calls.filter { $0.method == "Input.dispatchMouseEvent" } ?? []
        #expect(presses.map { $0.params["type"] as? String } == ["mousePressed", "mouseReleased"])
        #expect(presses.allSatisfy { $0.params["x"] as? Double == 308 && $0.params["y"] as? Double == 18 })
    }

    /// A click or key on a Chromium chat, as `debug.agent_pane click` and `debug.key {target: page}` deliver them,
    /// counts as the person's at the pane's gesture monitor. As in the app, the page's container view stays in the
    /// pane's window and Chromium draws in a child window over it, which gets the events: a capture's click then
    /// Return on a question card was refused with `transport.gesture_required` while the monitor never saw them.
    @Test func aClickAndAKeyInTheChromiumPageWindowRecordThePersonsGestures() async throws {
        let file = try #require(AgentPageTestRoot.page)
        let hosting = FakeChromiumHosting()
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file), pageHost: true, testRoot: true,
                                              chromium: hosting))
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let paneWindow = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 300), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
        paneWindow.isReleasedWhenClosed = false
        paneWindow.contentView = view
        defer { view.close(); paneWindow.close() }
        view.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(5)
        while !view.debugShowsChromium, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(view.debugShowsChromium)
        let container = try #require(view.chromiumPage?.contentView)
        #expect(container.window === paneWindow, "the page's container left the pane's window")
        // Chromium's own window, over the container.
        let pageFrame = paneWindow.convertToScreen(container.convert(container.bounds, to: nil))
        let pageWindow = NSWindow(contentRect: pageFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        pageWindow.isReleasedWhenClosed = false
        paneWindow.addChildWindow(pageWindow, ordered: .above)
        defer { pageWindow.close() }

        func mouseDown(atScreen screen: NSPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: pageWindow.convertPoint(fromScreen: screen),
                                            modifierFlags: [], timestamp: 0, windowNumber: pageWindow.windowNumber, context: nil,
                                            eventNumber: 0, clickCount: 1, pressure: 1))
        }
        let gestures = view.model.transport.gestures
        // A point off the page: no gesture.
        let outside = try #require(view.debugChromiumScreenPoint(x: 5000, y: 5000))
        view.judge(try mouseDown(atScreen: outside), eventWindow: pageWindow)
        #expect(!gestures.isAvailable, "a click off the Chromium page counted")
        // The element's point: the person's click, fresh enough to answer a question.
        let inside = try #require(view.debugChromiumScreenPoint(x: 20, y: 20))
        #expect(pageFrame.contains(inside), "\(inside) is not on the page \(pageFrame)")
        view.judge(try mouseDown(atScreen: inside), eventWindow: pageWindow)
        #expect(gestures.hasFreshAnswerGesture, "a click in the Chromium page window recorded no click gesture")
        #expect(AcpmuxPaneMethods.answerAllowed("_acpmux/permission_respond", gestures))
        #expect(gestures.consume())

        // Return in the page window, as debug.key {target: page} posts it (this process's own event).
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                windowNumber: pageWindow.windowNumber, context: nil, characters: "\r",
                                                charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        view.judge(key, eventWindow: pageWindow)
        #expect(gestures.consume(), "Return in the Chromium page window recorded no gesture")
    }
}
#endif
