import AppKit
import ObjectiveC
import WebKit
import Testing

@testable import CmuxBrowser

extension BrowserReplPasteboardRedirectTests {
    /// What another web view's page can read while a session tab's Paste
    /// runs (the redirect hands WebKit's own-turn lookups the tab's
    /// pasteboard, whichever web view they serve).
    @MainActor
    @Suite("Paste isolation", .serialized)
    struct PasteIsolation {
        /// Each test starts as a fresh app does, with no change count noted
        /// as one WebKit may hold a grant at; the redirect moves a tab
        /// pasteboard past noted ones, which would shift the counts these
        /// tests set up.
        init() {
            BrowserReplPasteboardRedirect.shared.forgetGrantableCounts()
        }

        private final class Loaded: NSObject, WKNavigationDelegate {
            var continuation: CheckedContinuation<Void, Never>?
            func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
                continuation?.resume()
                continuation = nil
            }
        }

        private func load(_ html: String, base: String = "https://example.com/") async -> WKWebView {
            let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            let loaded = Loaded()
            webView.navigationDelegate = loaded
            await withCheckedContinuation { continuation in
                loaded.continuation = continuation
                webView.loadHTMLString(html, baseURL: URL(string: base))
            }
            webView.navigationDelegate = nil
            return webView
        }

        private final class Reply: @unchecked Sendable {
            var value: Any?
            var done = false
        }

        /// A page in another web view that pastes from script
        /// (`execCommand("paste")` in a gesture) while a session tab's Paste
        /// runs must not read the tab's clipboard, also when that clipboard
        /// holds the page's own origin's data, which WebKit lets a page
        /// paste without asking. WebKit checks that origin on the system
        /// pasteboard (`+generalPasteboard`) before it grants the read, which
        /// diverts the command: the page reads an emptied private pasteboard
        /// and the command fails (`interfered`). Without its origin's data a
        /// page gets WebKit's paste callout, which only the person answers.
        @Test func aPageScriptPasteInAnotherWebViewDuringAPasteFailsTheCommand() async throws {
            let redirect = BrowserReplPasteboardRedirect.shared
            #expect(redirect.install())
            let tab = NSPasteboard.withUniqueName()
            defer { tab.releaseGlobally() }
            tab.clearContents()
            var copied: BrowserReplPasteboardRedirect.Outcome?
            var outcome: BrowserReplPasteboardRedirect.Outcome?
            var carriesOrigin = false
            let reply = Reply()
            try await AgentGestures.withStandInSystemPasteboard { _ in
                // The other page's copy puts its origin's data on the tab's
                // clipboard (an agent copied from that site).
                let otherView = await load(
                    """
                    <textarea id=o>selection</textarea><script>
                    addEventListener('copy', e => { e.clipboardData.setData('text/plain', 'tab text'); e.preventDefault(); });
                    addEventListener('paste', e => { window.__seen = e.clipboardData.getData('text/plain'); });
                    </script>
                    """,
                    base: "https://other.example/"
                )
                _ = try await otherView.evaluateJavaScript("(() => { const o = document.getElementById('o'); o.focus(); o.select(); return true })()")
                copied = await redirect.perform("Copy", in: otherView, pasteboard: tab, timeout: .seconds(10))
                carriesOrigin = tab.types?.contains(NSPasteboard.PasteboardType("com.apple.WebKit.custom-pasteboard-data")) == true
                _ = try await otherView.evaluateJavaScript("(() => { const o = document.getElementById('o'); o.value = ''; o.focus(); return true })()")
                // The session tab's paste handler keeps its Paste in flight.
                let tabView = await load(
                    """
                    <input id=i><script>
                    addEventListener('paste', e => { const end = Date.now() + 1500; while (Date.now() < end) {} });
                    </script>
                    """
                )
                _ = try await tabView.evaluateJavaScript("document.getElementById('i').focus(); true")
                let command = Task { @MainActor in
                    await redirect.perform("Paste", in: tabView, pasteboard: tab, timeout: .seconds(30), systemChangeCount: tab.changeCount + 1)
                }
                while redirect.redirectTarget(forLookupOf: NSPasteboard.Name.general.rawValue, fromWebKit: true) !== tab {
                    await Task.yield()
                }
                // The page pastes from script, in a gesture. Its reply may
                // never come: WebKit then waits for the person to answer a
                // paste callout.
                let script = "(() => { const o = document.getElementById('o'); o.focus(); document.execCommand('paste'); return o.value + '|' + (window.__seen ?? ''); })()"
                otherView.evaluateJavaScript(script) { value, _ in
                    reply.value = value
                    reply.done = true
                }
                outcome = await command.value
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                while !reply.done, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
            }
            #expect(copied == .completed)
            #expect(carriesOrigin, "the tab's clipboard does not carry the other page's origin, so this tests nothing")
            // A Bool, so a failure never prints the value.
            let readTheTabClipboard = (reply.value as? String)?.contains("tab text") == true
            #expect(!readTheTabClipboard, "a page's script paste in another web view read the session tab's clipboard during its Paste")
            #expect(outcome == .interfered, "the Paste completed although another web view read the clipboard during it")
            #expect(redirect.redirectTarget(forLookupOf: NSPasteboard.Name.general.rawValue, fromWebKit: true) == nil)
        }
    }
}
