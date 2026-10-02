import AppKit
import WebKit
import Testing

@testable import CmuxBrowser

/// The tab pasteboard a REPL Copy, Cut or Paste runs against must reach
/// WebKit's command and nothing else, and WebKit's command must never reach
/// the system pasteboard. These tests compare pasteboard identities only;
/// they never read or write the system pasteboard's contents.
@MainActor
@Suite("Browser REPL pasteboard redirect", .serialized)
struct BrowserReplPasteboardRedirectTests {
    private let general = NSPasteboard.Name.general.rawValue

    @Test func otherCodeGetsTheSystemPasteboardDuringAndAfterACommand() async throws {
        let system = NSPasteboard(name: .general)
        #expect(BrowserReplPasteboardRedirect.install())
        let tab = NSPasteboard.withUniqueName()
        defer { tab.releaseGlobally() }

        var during: [NSPasteboard] = []
        let outcome = await BrowserReplPasteboardRedirect.run(on: tab, timeout: .seconds(5)) { done in
            // The terminal or any other cmux code looking up the general
            // pasteboard while WebKit's command is in flight.
            during.append(NSPasteboard(name: .general))
            during.append(NSPasteboard.general)
            done()
        }
        #expect(outcome == .completed)
        #expect(during.count == 2)
        #expect(during.allSatisfy { $0 === system }, "a lookup by other code during a REPL command got the tab's pasteboard")
        #expect(NSPasteboard(name: .general) === system)
        #expect(BrowserReplPasteboardRedirect.redirectTarget(forLookupOf: general, fromWebKit: false) == nil)
    }

    @Test func webKitKeepsTheTabPasteboardUntilItFinishesEvenAfterATimeout() async throws {
        #expect(BrowserReplPasteboardRedirect.install())
        let tab = NSPasteboard.withUniqueName()
        var finish: (@MainActor () -> Void)?
        let outcome = await BrowserReplPasteboardRedirect.run(on: tab, timeout: .milliseconds(50)) { done in
            finish = done
        }
        #expect(outcome == .timedOut)
        // A paste WebKit performs late must still read the tab's pasteboard,
        // never the user's clipboard.
        #expect(BrowserReplPasteboardRedirect.redirectTarget(forLookupOf: general, fromWebKit: true) === tab)
        #expect(BrowserReplPasteboardRedirect.redirectTarget(forLookupOf: "Apple CFPasteboard find", fromWebKit: true) == nil)
        try #require(finish != nil)
        finish?()
        #expect(BrowserReplPasteboardRedirect.redirectTarget(forLookupOf: general, fromWebKit: true) == nil)
    }

    @Test func aCommandDoesNotStartWhileAnEarlierOneIsUnfinished() async throws {
        #expect(BrowserReplPasteboardRedirect.install())
        let first = NSPasteboard.withUniqueName()
        let second = NSPasteboard.withUniqueName()
        defer { second.releaseGlobally() }
        var finishFirst: (@MainActor () -> Void)?
        let firstOutcome = await BrowserReplPasteboardRedirect.run(on: first, timeout: .milliseconds(50)) { done in
            finishFirst = done
        }
        #expect(firstOutcome == .timedOut)

        var secondStarted = false
        let secondOutcome = await BrowserReplPasteboardRedirect.run(on: second, timeout: .milliseconds(50)) { done in
            secondStarted = true
            done()
        }
        #expect(secondOutcome == .busy)
        #expect(!secondStarted, "a second command ran while WebKit could still be using the first one's pasteboard")

        finishFirst?()
        let thirdOutcome = await BrowserReplPasteboardRedirect.run(on: second, timeout: .seconds(5)) { done in
            secondStarted = true
            done()
        }
        #expect(thirdOutcome == .completed)
        #expect(secondStarted)
    }
}

/// WebKit's real Paste, end to end: its pasteboard reads arrive through IPC
/// after the command starts, from WebCore, and must get the tab's pasteboard.
@MainActor
@Suite("Browser REPL pasteboard redirect in WebKit", .serialized)
struct BrowserReplPasteboardRedirectWebKitTests {
    private final class Loaded: NSObject, WKNavigationDelegate {
        var continuation: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            continuation?.resume()
            continuation = nil
        }
    }

    @Test func webKitsPasteReadsTheTabPasteboard() async throws {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let loaded = Loaded()
        webView.navigationDelegate = loaded
        await withCheckedContinuation { continuation in
            loaded.continuation = continuation
            webView.loadHTMLString(
                "<input id=i><script>addEventListener('paste', e => { window.pasted = e.isTrusted + ':' + e.clipboardData.getData('text/plain'); });</script>",
                baseURL: URL(string: "https://example.com/")
            )
        }
        _ = try await webView.evaluateJavaScript("document.getElementById('i').focus(); true")
        let tab = NSPasteboard.withUniqueName()
        defer { tab.releaseGlobally() }
        tab.clearContents()
        tab.setString("tab text", forType: .string)

        let outcome = await BrowserReplPasteboardRedirect.perform("Paste", in: webView, pasteboard: tab, timeout: .seconds(10))
        #expect(outcome == .completed)
        // Compared, never printed: a broken redirect would have pasted the
        // user's clipboard.
        let value = try await webView.evaluateJavaScript("document.getElementById('i').value") as? String
        let event = try await webView.evaluateJavaScript("window.pasted || ''") as? String
        #expect(value == "tab text", "WebKit's paste did not read the tab's pasteboard")
        #expect(event == "true:tab text", "the page did not get a trusted paste event with the tab's data")
        #expect(BrowserReplPasteboardRedirect.redirectTarget(forLookupOf: NSPasteboard.Name.general.rawValue, fromWebKit: true) == nil)
    }
}
