#if DEBUG
import AppKit
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// `debug.agent_pane click` on a chat shown by the shared page host (`agent.pageHost`): the
/// element is found in the page the chat shows, not in the pane's own unused WebKit view, which
/// holds no document (a capture slot answered "no visible element matches" for every selector,
/// even `textarea`, while `chat_state` worked on the same pane).
@Suite(.serialized)
@MainActor
struct AgentPaneDebugClickPageHostTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @Test func clickFindsAnElementOfThePageTheChatShows() async throws {
        let file = try #require(AgentPageTestRoot.page)
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file), pageHost: true,
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
        let hosting = LocatingHosting()
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file), pageHost: true,
                                              chromium: hosting))
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let deadline = Date().addingTimeInterval(5)
        while !view.debugShowsChromium, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(view.debugShowsChromium)

        let remove = await view.debugLocate(selector: "", text: "Remove red.png")
        #expect(remove["tag"] as? String == "button", "\(remove)")
        #expect(remove["x"] as? Double == 308, "\(remove)")
        #expect(await view.debugPress(x: 308, y: 18))
        let presses = hosting.page?.calls.filter { $0.method == "Input.dispatchMouseEvent" } ?? []
        #expect(presses.map { $0.params["type"] as? String } == ["mousePressed", "mouseReleased"])
        #expect(presses.allSatisfy { $0.params["x"] as? Double == 308 && $0.params["y"] as? Double == 18 })
    }
}

/// A Chromium host whose one page answers the click verb's locate script with a button at 308,18.
@MainActor
private final class LocatingHosting: PageChromiumHosting {
    let preference: BrowserDefaultEngine = .chromium
    let isAvailable = true
    private(set) var page: LocatingPage?

    func serves(_ page: PageDescriptor) -> Bool { true }

    func makePage(_ page: PageDescriptor) async throws -> any PageChromiumPage {
        let made = LocatingPage()
        self.page = made
        return made
    }
}

@MainActor
private final class LocatingPage: PageChromiumPage {
    let contentView = NSView()
    var onEvent: ((PageChromiumEvent) -> Void)?
    var resources: (@MainActor (URL) async -> PageChromiumResponse)?
    var occlusionRects: [CGRect] = []
    private(set) var calls: [(method: String, params: [String: any Sendable])] = []

    func devTools(_ method: String, params: [String: any Sendable]) async throws -> String {
        calls.append((method, params))
        if method == "Runtime.evaluate", (params["expression"] as? String)?.contains("no visible element matches") == true {
            return #"{"result":{"type":"string","value":"{\"x\":308,\"y\":18,\"tag\":\"button\"}"}}"#
        }
        return #"{"result":{}}"#
    }

    func load(_ url: URL) {}
    func reload() {}
    func setZoom(_ zoom: Double) {}
    func setFocused(_ focused: Bool) {}
    func setVisible(_ visible: Bool) {}
    func setSeeThrough(_ seeThrough: Bool) {}
    func close() {}
}
#endif
