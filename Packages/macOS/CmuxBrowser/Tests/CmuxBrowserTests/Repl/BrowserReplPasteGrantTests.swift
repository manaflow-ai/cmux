import AppKit
import WebKit
import Testing

@testable import CmuxBrowser

extension BrowserReplPasteboardRedirectTests {
    /// WebKit grants a web content process read access to the general
    /// pasteboard at one change count, keeps one grant per pasteboard name,
    /// and extends it to a process granted at an equal count instead of
    /// replacing it. Every private pasteboard the redirect hands WebKit
    /// starts near 0, so a process granted during an earlier command (or at
    /// a diverted command's private pasteboard) at count n would keep its
    /// grant through a later command whose tab pasteboard is at n, and could
    /// read that tab's clipboard. A command therefore never runs at a change
    /// count WebKit may still hold a grant at.
    @MainActor
    @Suite("Paste grants", .serialized)
    struct PasteGrants {
        private static let general = NSPasteboard.Name.general.rawValue

        private final class Loaded: NSObject, WKNavigationDelegate {
            var continuation: CheckedContinuation<Void, Never>?
            func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
                continuation?.resume()
                continuation = nil
            }
        }

        private func load(_ html: String) async -> WKWebView {
            let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            let loaded = Loaded()
            webView.navigationDelegate = loaded
            await withCheckedContinuation { continuation in
                loaded.continuation = continuation
                webView.loadHTMLString(html, baseURL: URL(string: "https://example.com/"))
            }
            webView.navigationDelegate = nil
            return webView
        }

        /// A fresh private pasteboard holding `text`, at change count
        /// `count` or the first above 0.
        private static func tabPasteboard(_ text: String, at count: Int = 1) -> NSPasteboard {
            let tab = NSPasteboard.withUniqueName()
            repeat { tab.clearContents() } while tab.changeCount < count
            tab.setString(text, forType: .string)
            return tab
        }

        /// Two tabs' Pastes in a row, each on a fresh private pasteboard:
        /// the second must not run at the count the first one's process was
        /// granted at, and it still pastes its own tab's text.
        @Test func aPasteNeverRunsAtTheCountAnEarlierPasteWasGrantedAt() async throws {
            let redirect = BrowserReplPasteboardRedirect.shared
            #expect(redirect.install())
            let first = Self.tabPasteboard("first tab")
            defer { first.releaseGlobally() }
            var firstOutcome: BrowserReplPasteboardRedirect.Outcome?
            var secondOutcome: BrowserReplPasteboardRedirect.Outcome?
            var granted = 0
            var second: NSPasteboard?
            var pasted: String?
            try await AgentGestures.withStandInSystemPasteboard { standIn in
                let firstView = await load("<input id=i>")
                _ = try await firstView.evaluateJavaScript("document.getElementById('i').focus(); true")
                firstOutcome = await redirect.perform("Paste", in: firstView, pasteboard: first, timeout: .seconds(10), systemChangeCount: standIn.changeCount)
                granted = first.changeCount

                let tab = Self.tabPasteboard("second tab", at: granted)
                second = tab
                try #require(tab.changeCount == granted, "the second tab's pasteboard does not start at the first one's count, so this tests nothing")
                let secondView = await load("<input id=i>")
                _ = try await secondView.evaluateJavaScript("document.getElementById('i').focus(); true")
                secondOutcome = await redirect.perform("Paste", in: secondView, pasteboard: tab, timeout: .seconds(10), systemChangeCount: standIn.changeCount)
                pasted = try await secondView.evaluateJavaScript("document.getElementById('i').value") as? String
            }
            defer { second?.releaseGlobally() }
            #expect(firstOutcome == .completed)
            #expect(secondOutcome == .completed)
            #expect(second?.changeCount != granted, "the second Paste ran at the count the first tab's process was granted at")
            // A Bool, so a failure never prints the value.
            let pastedItsOwnText = pasted == "second tab"
            #expect(pastedItsOwnText, "the second Paste did not paste its own tab's clipboard")
        }

        /// A diverted command hands WebKit's lookups an emptied private
        /// pasteboard, and the web view whose paste diverted it may be
        /// granted there; a later command must not run at that count.
        @Test func aCommandNeverRunsAtACountADivertedCommandHandedOut() async throws {
            let redirect = BrowserReplPasteboardRedirect.shared
            #expect(redirect.install())
            let diverted = NSPasteboard.withUniqueName()
            defer { diverted.releaseGlobally() }
            diverted.clearContents()
            var finish: (@MainActor () -> Void)?
            let command = Task { @MainActor in
                await redirect.run(on: diverted, timeout: .seconds(30), endWebContent: { true }) { done in
                    finish = done
                }
            }
            for _ in 0..<1_000 where finish == nil { await Task.yield() }
            try #require(finish != nil)
            // Another web view's paste, started by the app, during the command.
            let sinkCount = redirect.redirectTarget(forLookupOf: Self.general, origin: .webKitCalledByTheApp)?.changeCount
            finish?()
            #expect(await command.value == .interfered)
            let handedOut = try #require(sinkCount)

            let tab = NSPasteboard.withUniqueName()
            defer { tab.releaseGlobally() }
            while tab.changeCount < handedOut { tab.clearContents() }
            tab.setString("tab text", forType: .string)
            var seen: Int?
            let second = await redirect.run(on: tab, timeout: .seconds(5), endWebContent: { true }) { done in
                seen = redirect.redirectTarget(forLookupOf: Self.general, origin: .webKitOnItsOwnTurn)?.changeCount
                done()
            }
            #expect(second == .completed)
            #expect(seen != nil)
            #expect(seen != handedOut, "a command ran at the count a diverted command's private pasteboard was handed out at")
            #expect(tab.string(forType: .string) == "tab text", "moving the tab's pasteboard past that count lost its contents")
        }
    }
}
