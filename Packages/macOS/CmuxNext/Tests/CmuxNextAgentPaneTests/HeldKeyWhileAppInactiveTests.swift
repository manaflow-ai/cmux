import AppKit
import CmuxNextPagesTestSupport
import CmuxNextTestSupport
import Testing
@testable import CmuxNextAgentPane
@testable import CmuxNextPages

/// A key the New Tab key hold kept reaches the New Tab field also while cmux is not the active app.
///
/// With the app not active no window is key. Chromium drops a key event sent to a page window that
/// is not key, and the page's document has no focus, so it sends no focus events: the page's input
/// readiness never turns ready, and the router's type-ahead kept the replayed key for a readiness
/// that never came. The field had the caret but stayed empty: on the fleet (`CMUX_NEXT_NO_ACTIVATE`,
/// a script's or a background Cmd-T) the first key, a `/` that opens the slash menu included, was
/// lost in 24 of 24 openings. The hold now types the key's text into its own ready page through the
/// page's input bridge, after the text of the keys before it.
@Suite(.serialized, .closesItsWindows)
@MainActor
struct HeldKeyWhileAppInactiveTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private func pane() async throws -> (AgentPaneView, FakeChromiumPage, NSWindow) {
        _ = NSApplication.shared
        let file = try #require(AgentPageTestRoot.page)
        let hosting = FakeChromiumHosting()
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file),
                                              pageHost: true, chromium: hosting))
        let page = try #require(view.page)
        await page.chromiumStart?.value
        let chromium = try #require(hosting.made.first)
        chromium.answer = { method, _ in method == "Runtime.evaluate" ? #"{"result":{"type":"boolean","value":true}}"# : nil }
        let window = NSWindow(contentRect: view.bounds, styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        return (view, chromium, window)
    }

    private static func key(_ characters: String, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                      isARepeat: false, keyCode: 0))
    }

    /// The texts typed into the page's focused field through its input bridge, in order.
    private static func typed(_ chromium: FakeChromiumPage) -> [String] {
        chromium.calls.compactMap { call -> String? in
            guard call.method == "Runtime.evaluate", let expression = call.params["expression"] as? String,
                  let range = expression.range(of: "document.execCommand('insertText', false, ") else { return nil }
            let rest = expression[range.upperBound...]
            guard let end = rest.range(of: ");") else { return nil }
            return (try? JSONSerialization.jsonObject(with: Data(rest[..<end.lowerBound].utf8), options: [.fragmentsAllowed])) as? String
        }
    }

    @Test(arguments: 0..<20) func heldKeysReachTheFieldWhileTheAppIsNotActive(round: Int) async throws {
        let (view, chromium, window) = try await pane()
        defer { view.page?.close(); window.close() }
        let taken = try ["/", "m", "o"].map { view.typeHeldText(of: try Self.key($0), appIsActive: false) }
        await view.heldKeyTyping?.value
        #expect(taken == [true, true, true], "round \(round): the page took \(taken) of the held keys; the rest went on as key events Chromium drops")
        #expect(Self.typed(chromium).joined() == "/mo", "round \(round): the field got \(Self.typed(chromium)) of the held keys")
    }

    /// The person's own path (the app active, the page window key) keeps the key event: the page
    /// sees each keydown.
    @Test func heldKeysStayKeyEventsWhileTheAppIsActive() async throws {
        let (view, chromium, window) = try await pane()
        defer { view.page?.close(); window.close() }
        #expect(!view.typeHeldText(of: try Self.key("/"), appIsActive: true))
        await view.heldKeyTyping?.value
        #expect(Self.typed(chromium).isEmpty)
    }

    /// A key that types no text (Return, an arrow, a chord) is no insertion: it goes on as a key event.
    @Test func keysThatTypeNoTextStayKeyEvents() async throws {
        let (view, chromium, window) = try await pane()
        defer { view.page?.close(); window.close() }
        #expect(!view.typeHeldText(of: try Self.key("\r"), appIsActive: false))
        #expect(!view.typeHeldText(of: try Self.key(String(UnicodeScalar(NSUpArrowFunctionKey)!)), appIsActive: false))
        #expect(!view.typeHeldText(of: try Self.key("a", modifiers: .command), appIsActive: false))
        await view.heldKeyTyping?.value
        #expect(Self.typed(chromium).isEmpty)
    }
}
