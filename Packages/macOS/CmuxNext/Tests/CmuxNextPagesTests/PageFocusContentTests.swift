import AppKit
@testable import CmuxNextPages
import CmuxNextSettings
import CmuxNextTestSupport
import Testing

/// PANE-FOCUS (user 2026-10-20, "monaco editor on focus does not get focus"): the app gives a page's
/// web view the keyboard, but WebKit focuses no DOM element on its own, so typing reached the body.
/// The host now tells the page on its command stream (`focusContent`) every time the web view
/// becomes first responder, and the page focuses its primary input (Monaco's text area) when nothing
/// in it has focus (plans/cmux-next/pane-focus-DESIGN.md row P1).
@MainActor
@Suite(.closesItsWindows)
struct PageFocusContentTests {
    /// Every page kind takes `focusContent`: the shared commands carry it.
    @Test(arguments: ["editor", "markdown", "diff", "plain"])
    func everyPageTakesFocusContent(kind: String) async throws {
        let descriptor: PageDescriptor = switch kind {
        case "editor": .editor
        case "markdown": .markdown
        case "diff": .diff
        default: PageDescriptor(id: "cmux.focus-test", resource: "focus-test", namespaces: ["cmux.focus-test."])
        }
        let router = PageRouter(descriptor: descriptor, routes: [])
        var sent: [JSONValue] = []
        router.send = { sent.append($0) }
        let reply = await router.handle(["t": "sub", "id": 1, "stream": .string(PageNativeOp.pageCommand)])
        #expect(reply["t"]?.stringValue == "ok")
        #expect(router.publishCommand(PageNativeOp.focusContent))
        let commands = sent.compactMap { $0["data"]?["command"]?.stringValue }
        #expect(commands == [PageNativeOp.focusContent])
    }

    /// The page's web view reports each time it becomes first responder (a pane click, a tab
    /// switch, Cmd-Opt-Arrow, a restore): that is when the host sends `focusContent`.
    @Test func webViewBecomingFirstResponderReportsIt() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        defer { window.closeAfterTest() }
        let other = NSTextField(frame: NSRect(x: 0, y: 0, width: 50, height: 20))
        let web = PageWKWebView(frame: NSRect(x: 0, y: 40, width: 200, height: 160), configuration: .init())
        window.contentView?.addSubview(other)
        window.contentView?.addSubview(web)
        var reports = 0
        web.onBecameFirstResponder = { reports += 1 }
        #expect(window.makeFirstResponder(web))
        #expect(reports == 1)
        #expect(window.makeFirstResponder(other))
        #expect(window.makeFirstResponder(web))
        #expect(reports == 2)
    }
}
