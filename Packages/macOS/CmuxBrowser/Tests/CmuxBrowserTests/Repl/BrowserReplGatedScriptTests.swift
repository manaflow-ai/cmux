import AppKit
import Testing
import WebKit

@testable import CmuxBrowser

/// A native write into a page (the sign-in sheet's fill) is authorized right
/// before WebKit gets the script, in the same main-actor turn: a check made
/// before an earlier suspension can be stale by then (the session detached,
/// was reset, or the tab changed hands). `onlyIf` is that check, and when it
/// fails the script never reaches the page.
@MainActor
@Suite("Gated scripts", .serialized)
struct BrowserReplGatedScriptTests {
    private final class Loaded: NSObject, WKNavigationDelegate {
        var continuation: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            continuation?.resume()
            continuation = nil
        }
    }

    private static func page() async -> (WKWebView, Loaded) {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let loaded = Loaded()
        webView.navigationDelegate = loaded
        await withCheckedContinuation { continuation in
            loaded.continuation = continuation
            webView.loadHTMLString("<input id=field>", baseURL: URL(string: "https://allowed.test/"))
        }
        return (webView, loaded)
    }

    private static let world = WKContentWorld.world(name: "cmux-gated-script-tests")
    private static let write = "document.getElementById('field').value = value; return 'filled'"
    private static let read = "return document.getElementById('field').value"

    @Test func aScriptWhoseCheckFailsAtDispatchNeverReachesThePage() async throws {
        let (webView, loaded) = await Self.page()
        defer { _ = loaded }
        // The check passed when the caller looked, and fails by the time
        // the script would go out (the session detached in between).
        var stillAllowed = true
        let detach = { stillAllowed = false }
        detach()
        var refused: BrowserReplDriverError?
        do {
            _ = try await webView.browserReplCallAsyncJavaScript(
                Self.write,
                arguments: ["value": "s3cret"],
                in: nil,
                contentWorld: Self.world,
                userGesture: false,
                onlyIf: { stillAllowed }
            )
        } catch let error as BrowserReplDriverError {
            refused = error
        }
        #expect(refused?.code == "cancelled", "a script whose check failed at dispatch ran: \(String(describing: refused))")
        let value = try await webView.browserReplCallAsyncJavaScript(Self.read, arguments: [:], in: nil, contentWorld: Self.world, userGesture: false)
        #expect(value as? String == "", "the page received the write after its check failed")

        // A check that holds at dispatch lets the write through.
        let filled = try await webView.browserReplCallAsyncJavaScript(
            Self.write,
            arguments: ["value": "typed"],
            in: nil,
            contentWorld: Self.world,
            userGesture: false,
            onlyIf: { true }
        )
        #expect(filled as? String == "filled")
    }
}
