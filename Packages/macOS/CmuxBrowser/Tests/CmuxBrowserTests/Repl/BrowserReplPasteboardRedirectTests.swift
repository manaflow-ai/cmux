import AppKit
import WebKit
import Testing

@testable import CmuxBrowser

/// The tab pasteboard a REPL Copy, Cut or Paste runs against must reach
/// WebKit's command and nothing else, only until the command's timeout, and
/// WebKit's command must never reach the system pasteboard. These tests
/// compare pasteboard identities and change counts; they never read or write
/// the system pasteboard's contents, and they never print a page value that
/// a broken redirect could have filled from it.
///
/// The redirect is process-wide, so every test runs in one serialized suite:
/// the nested suites must not run alongside each other.
@MainActor
@Suite("Browser REPL pasteboard redirect", .serialized)
struct BrowserReplPasteboardRedirectTests {
    private static let general = NSPasteboard.Name.general.rawValue

    @MainActor
    @Suite("Lookups", .serialized)
    struct Lookups {
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

        @Test func theRedirectEndsAtTheTimeoutEvenWhenWebKitHasNotFinished() async throws {
            #expect(BrowserReplPasteboardRedirect.install())
            let tab = NSPasteboard.withUniqueName()
            defer { tab.releaseGlobally() }
            var finish: (@MainActor () -> Void)?
            let outcome = await BrowserReplPasteboardRedirect.run(on: tab, timeout: .milliseconds(50)) { done in
                finish = done
            }
            #expect(outcome == .timedOut)
            // A person pasting or copying in another browser pane after the
            // timeout must reach their own clipboard, not the tab's.
            #expect(
                BrowserReplPasteboardRedirect.redirectTarget(forLookupOf: general, fromWebKit: true) == nil,
                "the redirect outlived its command's timeout"
            )
            try #require(finish != nil)
            finish?()
            #expect(BrowserReplPasteboardRedirect.redirectTarget(forLookupOf: general, fromWebKit: true) == nil)
        }

        @Test func aCommandDoesNotStartWhileAnEarlierOneIsUnfinishedAndNothingIsRedirectedMeanwhile() async throws {
            #expect(BrowserReplPasteboardRedirect.install())
            let first = NSPasteboard.withUniqueName()
            let second = NSPasteboard.withUniqueName()
            defer {
                first.releaseGlobally()
                second.releaseGlobally()
            }
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
            #expect(!secondStarted, "a second command ran while WebKit could still write the first one's late copy into its pasteboard")
            #expect(
                BrowserReplPasteboardRedirect.redirectTarget(forLookupOf: general, fromWebKit: true) == nil,
                "an abandoned command kept the redirect while later commands waited for it"
            )

            finishFirst?()
            let thirdOutcome = await BrowserReplPasteboardRedirect.run(on: second, timeout: .seconds(5)) { done in
                secondStarted = true
                done()
            }
            #expect(thirdOutcome == .completed)
            #expect(secondStarted)
        }

        @Test func whenFinishedRunsOnceWhenWebKitFinishesOrAtOnceWhenTheCommandDoesNotStart() async throws {
            #expect(BrowserReplPasteboardRedirect.install())
            let tab = NSPasteboard.withUniqueName()
            let other = NSPasteboard.withUniqueName()
            defer {
                tab.releaseGlobally()
                other.releaseGlobally()
            }
            var finished = 0
            var finish: (@MainActor () -> Void)?
            let outcome = await BrowserReplPasteboardRedirect.run(on: tab, timeout: .milliseconds(50), whenFinished: { finished += 1 }) { done in
                finish = done
            }
            #expect(outcome == .timedOut)
            #expect(finished == 0, "a timeout is not WebKit finishing the command")

            var busyFinished = 0
            let busy = await BrowserReplPasteboardRedirect.run(on: other, timeout: .milliseconds(50), whenFinished: { busyFinished += 1 }) { done in
                done()
            }
            #expect(busy == .busy)
            #expect(busyFinished == 1)

            try #require(finish != nil)
            finish?()
            finish?()
            #expect(finished == 1)
        }
    }

    /// WebKit's real commands, end to end: its pasteboard reads and writes
    /// arrive through IPC after the command starts, from WebCore.
    @MainActor
    @Suite("WebKit", .serialized)
    struct InWebKit {
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

        @Test func webKitsPasteReadsTheTabPasteboard() async throws {
            let webView = await load(
                "<input id=i><script>addEventListener('paste', e => { window.pasted = e.isTrusted + ':' + e.clipboardData.getData('text/plain'); });</script>"
            )
            _ = try await webView.evaluateJavaScript("document.getElementById('i').focus(); true")
            let tab = NSPasteboard.withUniqueName()
            defer { tab.releaseGlobally() }
            tab.clearContents()
            tab.setString("tab text", forType: .string)

            let outcome = await BrowserReplPasteboardRedirect.perform("Paste", in: webView, pasteboard: tab, timeout: .seconds(10))
            if tab.changeCount >= NSPasteboard.general.changeCount {
                // A system clipboard this young could match the tab's change
                // count, which WebKit's access check compares; Paste then
                // does not run through WebKit at all.
                #expect(outcome == .unavailable)
                return
            }
            #expect(outcome == .completed)
            // A broken redirect would have pasted the user's clipboard.
            let value = try await webView.evaluateJavaScript("document.getElementById('i').value") as? String
            let event = try await webView.evaluateJavaScript("window.pasted || ''") as? String
            // Bools, so a failure never prints the values.
            let pastedTabText = value == "tab text"
            let trustedEvent = event == "true:tab text"
            #expect(pastedTabText, "WebKit's paste did not read the tab's pasteboard")
            #expect(trustedEvent, "the page did not get a trusted paste event with the tab's data")
            #expect(BrowserReplPasteboardRedirect.redirectTarget(forLookupOf: general, fromWebKit: true) == nil)
        }

        /// WebKit's late-read refusal compares change counts; a Paste whose
        /// tab pasteboard is not below the system's could pass it.
        @Test func aPasteWhoseLateReadsWebKitCouldAllowDoesNotStart() async throws {
            let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
            let tab = NSPasteboard.withUniqueName()
            defer { tab.releaseGlobally() }
            tab.clearContents()
            tab.setString("tab text", forType: .string)
            var finished = false
            let outcome = await BrowserReplPasteboardRedirect.perform(
                "Paste",
                in: webView,
                pasteboard: tab,
                timeout: .seconds(1),
                systemChangeCount: tab.changeCount,
                whenWebKitFinishes: { finished = true }
            )
            #expect(outcome == .unavailable)
            #expect(finished)
            #expect(BrowserReplPasteboardRedirect.redirectTarget(forLookupOf: general, fromWebKit: true) == nil)
        }

        /// A page that keeps its paste handler running past the timeout reads
        /// the clipboard late, after the redirect has ended. The late read
        /// must find nothing: neither the tab's clipboard, which the agent
        /// may have meant for a page it trusts, nor the person's.
        @Test func aPasteReadAfterTheTimeoutGetsNothing() async throws {
            let webView = await load(
                """
                <input id=i><script>
                addEventListener('paste', e => {
                  const end = Date.now() + 1500;
                  while (Date.now() < end) {}
                  window.late = e.clipboardData.getData('text/plain');
                });
                </script>
                """
            )
            _ = try await webView.evaluateJavaScript("document.getElementById('i').focus(); true")
            let tab = NSPasteboard.withUniqueName()
            defer { tab.releaseGlobally() }
            tab.clearContents()
            tab.setString("tab text", forType: .string)

            let outcome = await BrowserReplPasteboardRedirect.perform("Paste", in: webView, pasteboard: tab, timeout: .milliseconds(300))
            if tab.changeCount >= NSPasteboard.general.changeCount {
                #expect(outcome == .unavailable)
                return
            }
            #expect(outcome == .timedOut)
            #expect(
                BrowserReplPasteboardRedirect.redirectTarget(forLookupOf: general, fromWebKit: true) == nil,
                "the redirect outlived the paste's timeout"
            )
            // Script runs after the handler and WebKit's default paste are done.
            let late = try await webView.evaluateJavaScript("window.late ?? 'unset'") as? String
            let value = try await webView.evaluateJavaScript("document.getElementById('i').value") as? String
            // Bools, so a failure never prints the values.
            let lateReadWasEmpty = late == ""
            let nothingInserted = value == ""
            #expect(lateReadWasEmpty, "a paste handler that outlived the timeout still read clipboard data")
            #expect(nothingInserted, "WebKit's late default paste still inserted clipboard data")
        }

        /// Proof for WebKit's Copy and Cut of rich content (formatting, a
        /// link, an image): every write lands on the tab's pasteboard and
        /// none reaches the system pasteboard by any route, including
        /// `+[NSPasteboard generalPasteboard]`, which does not go through the
        /// `+pasteboardWithName:` lookup the redirect hooks.
        @Test(arguments: ["Copy", "Cut"])
        func webKitsCopyAndCutWriteOnlyTheTabPasteboard(command: String) async throws {
            let webView = await load(
                """
                <div id=ed contenteditable><b>bold</b> <a href="https://example.com/x">link</a> \
                <img src="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="> text</div>
                """
            )
            _ = try await webView.evaluateJavaScript(
                "const ed = document.getElementById('ed'); ed.focus(); const r = document.createRange(); r.selectNodeContents(ed); getSelection().removeAllRanges(); getSelection().addRange(r); true"
            )
            let tab = NSPasteboard.withUniqueName()
            defer { tab.releaseGlobally() }
            tab.clearContents()
            let systemBefore = NSPasteboard.general.changeCount

            let outcome = await BrowserReplPasteboardRedirect.perform(command, in: webView, pasteboard: tab, timeout: .seconds(10))
            #expect(outcome == .completed)
            #expect(NSPasteboard.general.changeCount == systemBefore, "WebKit's \(command) wrote the system pasteboard")
            let types = Set(tab.types ?? [])
            #expect(types.contains(.html), "WebKit's \(command) did not write its HTML to the tab's pasteboard")
            #expect(types.contains(.string), "WebKit's \(command) did not write its text to the tab's pasteboard")
            let copiedTheSelection = tab.string(forType: .string)?.contains("bold link") == true
            #expect(copiedTheSelection)
        }
    }
}
