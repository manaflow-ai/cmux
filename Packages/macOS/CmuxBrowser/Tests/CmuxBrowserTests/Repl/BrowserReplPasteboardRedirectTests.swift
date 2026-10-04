import AppKit
import ObjectiveC
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
            #expect(BrowserReplPasteboardRedirect.shared.install())
            let tab = NSPasteboard.withUniqueName()
            defer { tab.releaseGlobally() }

            var during: [NSPasteboard] = []
            let outcome = await BrowserReplPasteboardRedirect.shared.run(on: tab, timeout: .seconds(5), endWebContent: { true }) { done in
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
            #expect(BrowserReplPasteboardRedirect.shared.redirectTarget(forLookupOf: general, fromWebKit: false) == nil)
        }

        /// At the timeout the command's web content is ended and the
        /// redirect ends in the same turn: a person pasting or copying in
        /// another browser pane afterwards reaches their own clipboard, and
        /// the page that outlived the timeout can no longer write anything.
        @Test func atTheTimeoutTheWebContentIsEndedAndTheRedirectEnds() async throws {
            #expect(BrowserReplPasteboardRedirect.shared.install())
            let tab = NSPasteboard.withUniqueName()
            defer { tab.releaseGlobally() }
            var finish: (@MainActor () -> Void)?
            var ended = 0
            var finished = 0
            var redirectedWhenEnded: NSPasteboard?
            let outcome = await BrowserReplPasteboardRedirect.shared.run(
                on: tab,
                timeout: .milliseconds(50),
                endWebContent: {
                    ended += 1
                    redirectedWhenEnded = BrowserReplPasteboardRedirect.shared.redirectTarget(forLookupOf: general, fromWebKit: true)
                    return true
                },
                whenFinished: { finished += 1 }
            ) { done in
                finish = done
            }
            #expect(outcome == .timedOut)
            #expect(ended == 1)
            #expect(redirectedWhenEnded === tab, "the redirect ended before the web content did, so a late write could reach the system pasteboard")
            #expect(
                BrowserReplPasteboardRedirect.shared.redirectTarget(forLookupOf: general, fromWebKit: true) == nil,
                "the redirect outlived its command's timeout"
            )
            #expect(finished == 1, "ending the web content finishes the command")
            try #require(finish != nil)
            finish?()
            #expect(finished == 1)
            #expect(BrowserReplPasteboardRedirect.shared.redirectTarget(forLookupOf: general, fromWebKit: true) == nil)
        }

        /// When the web content can no longer be ended (its process came to
        /// hold a tab no session created), WebKit's lookups keep getting the
        /// command's pasteboard until WebKit finishes within the grace (60 s
        /// here, so WebKit finishes first), so a late write never reaches the
        /// system pasteboard. Later commands, from any tab, wait and name the
        /// tab they waited for.
        @Test func whenTheWebContentCannotBeEndedTheRedirectLastsUntilWebKitFinishesWithinTheGrace() async throws {
            #expect(BrowserReplPasteboardRedirect.shared.install())
            let first = NSPasteboard.withUniqueName()
            let second = NSPasteboard.withUniqueName()
            defer {
                first.releaseGlobally()
                second.releaseGlobally()
            }
            var finishFirst: (@MainActor () -> Void)?
            var firstFinished = 0
            let firstOutcome = await BrowserReplPasteboardRedirect.shared.run(
                on: first,
                tab: "tab A",
                timeout: .milliseconds(50),
                grace: .seconds(60),
                endWebContent: { false },
                whenFinished: { firstFinished += 1 }
            ) { done in
                finishFirst = done
            }
            #expect(firstOutcome == .timedOutStillRunning)
            #expect(firstFinished == 0)
            #expect(
                BrowserReplPasteboardRedirect.shared.redirectTarget(forLookupOf: general, fromWebKit: true) === first,
                "a late write of a command whose web content still runs could reach the system pasteboard"
            )
            #expect(BrowserReplPasteboardRedirect.shared.redirectTarget(forLookupOf: general, fromWebKit: false) == nil)

            var secondStarted = false
            let secondOutcome = await BrowserReplPasteboardRedirect.shared.run(on: second, tab: "tab B", timeout: .milliseconds(50), endWebContent: { true }) { done in
                secondStarted = true
                done()
            }
            #expect(secondOutcome == .busy(tab: "tab A"))
            #expect(!secondStarted, "a second command ran while WebKit could still write the first one's late copy into its pasteboard")

            // WebKit finishes the first command late: what it wrote meanwhile
            // stayed on the first command's pasteboard, which is emptied and
            // released now.
            first.clearContents()
            first.setString("late write", forType: .string)
            try #require(finishFirst != nil)
            finishFirst?()
            #expect(firstFinished == 1)
            #expect(BrowserReplPasteboardRedirect.shared.redirectTarget(forLookupOf: general, fromWebKit: true) == nil)
            #expect(first.types?.isEmpty ?? true, "the abandoned command's pasteboard kept its late write")

            let thirdOutcome = await BrowserReplPasteboardRedirect.shared.run(on: second, timeout: .seconds(5), endWebContent: { true }) { done in
                secondStarted = true
                done()
            }
            #expect(thirdOutcome == .completed)
            #expect(secondStarted)
        }

        /// A command that waited for an earlier one gets its own timeout once
        /// it starts, so its tab is not ended for the time the earlier one
        /// took. Time is a manual clock, so the order never depends on load.
        @Test func aCommandThatWaitedGetsItsOwnTimeout() async throws {
            #expect(BrowserReplPasteboardRedirect.shared.install())
            let first = NSPasteboard.withUniqueName()
            let second = NSPasteboard.withUniqueName()
            defer {
                first.releaseGlobally()
                second.releaseGlobally()
            }
            let clock = ManualClock()
            let firstRun = Task { @MainActor in
                await BrowserReplPasteboardRedirect.shared.run(on: first, timeout: .seconds(5), clock: clock, endWebContent: { true }) { _ in }
            }
            try await settle { BrowserReplPasteboardRedirect.shared.redirectTarget(forLookupOf: general, fromWebKit: true) === first }

            clock.advance(by: .seconds(1))
            var secondEnded = false
            var finishSecond: (@MainActor () -> Void)?
            let secondRun = Task { @MainActor in
                await BrowserReplPasteboardRedirect.shared.run(
                    on: second,
                    timeout: .seconds(5),
                    clock: clock,
                    endWebContent: {
                        secondEnded = true
                        return true
                    }
                ) { done in
                    finishSecond = done
                }
            }
            await clock.waitForSleepers(2)

            // The first command reaches its timeout at 5 s and is ended; the
            // second starts then, with its own 5 s.
            clock.advance(by: .seconds(4))
            #expect(await firstRun.value == .timedOut)
            try await settle { finishSecond != nil }
            #expect(BrowserReplPasteboardRedirect.shared.redirectTarget(forLookupOf: general, fromWebKit: true) === second)

            // 7 s: past a deadline shared with the wait, inside its own.
            clock.advance(by: .seconds(2))
            await settleTurns()
            #expect(!secondEnded, "a command that waited was ended for the earlier command's time")
            finishSecond?()
            #expect(await secondRun.value == .completed)
        }

        /// A caller that stops waiting (its REPL call was cancelled) does not
        /// shorten the command: the web content is ended at the timeout, not
        /// at the cancellation, so the timeout the error names is the one
        /// that happened.
        @Test func aCancelledCallerDoesNotEndTheWebContentBeforeTheTimeout() async throws {
            #expect(BrowserReplPasteboardRedirect.shared.install())
            let tab = NSPasteboard.withUniqueName()
            defer { tab.releaseGlobally() }
            let clock = ManualClock()
            var ended = false
            let run = Task { @MainActor in
                await BrowserReplPasteboardRedirect.shared.run(
                    on: tab,
                    timeout: .seconds(5),
                    clock: clock,
                    endWebContent: {
                        ended = true
                        return true
                    }
                ) { _ in }
            }
            try await settle { BrowserReplPasteboardRedirect.shared.redirectTarget(forLookupOf: general, fromWebKit: true) === tab }
            run.cancel()
            await settleTurns()
            #expect(!ended, "a cancelled caller ended the web content before the timeout")
            #expect(BrowserReplPasteboardRedirect.shared.redirectTarget(forLookupOf: general, fromWebKit: true) === tab)

            clock.advance(by: .seconds(5))
            #expect(await run.value == .timedOut)
            #expect(ended)
            #expect(BrowserReplPasteboardRedirect.shared.redirectTarget(forLookupOf: general, fromWebKit: true) == nil)
        }

        /// A command whose web content could not be ended at the timeout
        /// (another tab no session created shares its process) keeps the
        /// redirect for at most one more timeout: then the web content is
        /// ended regardless and the redirect ends, so another web view's
        /// copies and pastes reach the system pasteboard again and nothing
        /// the page writes later does.
        @Test func aCommandStillRunningAfterItsTimeoutIsEndedOneTimeoutLater() async throws {
            #expect(BrowserReplPasteboardRedirect.shared.install())
            let tab = NSPasteboard.withUniqueName()
            defer { tab.releaseGlobally() }
            let clock = ManualClock()
            var asked = 0
            var finished = 0
            let run = Task { @MainActor in
                await BrowserReplPasteboardRedirect.shared.run(
                    on: tab,
                    tab: "tab A",
                    timeout: .seconds(5),
                    clock: clock,
                    endWebContent: {
                        asked += 1
                        return asked > 1
                    },
                    whenFinished: { finished += 1 }
                ) { _ in }
            }
            await clock.waitForSleepers(1)
            clock.advance(by: .seconds(5))
            #expect(await run.value == .timedOutStillRunning)
            #expect(asked == 1)
            #expect(BrowserReplPasteboardRedirect.shared.redirectTarget(forLookupOf: general, fromWebKit: true) === tab)

            await clock.waitForSleepers(1)
            clock.advance(by: .seconds(4))
            await settleTurns()
            #expect(asked == 1, "the web content was ended before its second timeout")
            clock.advance(by: .seconds(1))
            try await settle { asked == 2 }
            #expect(
                BrowserReplPasteboardRedirect.shared.redirectTarget(forLookupOf: general, fromWebKit: true) == nil,
                "the redirect outlived the command's second timeout"
            )
            #expect(finished == 1)
            #expect(tab.types?.isEmpty ?? true)
        }

        /// Lets main-actor work queued by the test run, until `condition`.
        private func settle(_ condition: @MainActor () -> Bool) async throws {
            for _ in 0..<1_000 where !condition() { await Task.yield() }
            try #require(condition())
        }

        private func settleTurns() async {
            for _ in 0..<200 { await Task.yield() }
        }

        @Test func whenFinishedRunsOnceWhenWebKitFinishesOrAtOnceWhenTheCommandDoesNotStart() async throws {
            #expect(BrowserReplPasteboardRedirect.shared.install())
            let tab = NSPasteboard.withUniqueName()
            let other = NSPasteboard.withUniqueName()
            defer {
                tab.releaseGlobally()
                other.releaseGlobally()
            }
            var finished = 0
            var finish: (@MainActor () -> Void)?
            let outcome = await BrowserReplPasteboardRedirect.shared.run(
                on: tab,
                timeout: .milliseconds(50),
                grace: .seconds(60),
                endWebContent: { false },
                whenFinished: { finished += 1 }
            ) { done in
                finish = done
            }
            #expect(outcome == .timedOutStillRunning)
            #expect(finished == 0, "a timeout is not WebKit finishing the command")

            var busyFinished = 0
            let busy = await BrowserReplPasteboardRedirect.shared.run(
                on: other,
                timeout: .milliseconds(50),
                endWebContent: { true },
                whenFinished: { busyFinished += 1 }
            ) { done in
                done()
            }
            #expect(busy == .busy(tab: ""))
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

        /// The system pasteboard is a stand-in, so a broken redirect pastes
        /// the stand-in's text, never the person's clipboard. The system's
        /// change count is given above the tab's, so the paste always runs
        /// through WebKit (``aPasteWhoseLateReadsWebKitCouldAllowDoesNotStart``
        /// covers the other side of that check).
        @Test func webKitsPasteReadsTheTabPasteboard() async throws {
            let standIn = Self.makeStandIn()
            defer { standIn.releaseGlobally() }
            let tab = NSPasteboard.withUniqueName()
            defer { tab.releaseGlobally() }
            tab.clearContents()
            tab.setString("tab text", forType: .string)
            var outcome: BrowserReplPasteboardRedirect.Outcome?
            var value: String?
            var event: String?
            try await Self.withStandInSystemPasteboard(standIn) {
                let webView = await load(
                    "<input id=i><script>addEventListener('paste', e => { window.pasted = e.isTrusted + ':' + e.clipboardData.getData('text/plain'); });</script>"
                )
                _ = try await webView.evaluateJavaScript("document.getElementById('i').focus(); true")
                outcome = await BrowserReplPasteboardRedirect.shared.perform(
                    "Paste",
                    in: webView,
                    pasteboard: tab,
                    timeout: .seconds(10),
                    systemChangeCount: tab.changeCount + 1
                )
                value = try await webView.evaluateJavaScript("document.getElementById('i').value") as? String
                event = try await webView.evaluateJavaScript("window.pasted || ''") as? String
            }
            #expect(outcome == .completed)
            // Bools, so a failure never prints the values.
            let pastedTabText = value == "tab text"
            let trustedEvent = event == "true:tab text"
            #expect(pastedTabText, "WebKit's paste did not read the tab's pasteboard")
            #expect(trustedEvent, "the page did not get a trusted paste event with the tab's data")
            #expect(BrowserReplPasteboardRedirect.shared.redirectTarget(forLookupOf: general, fromWebKit: true) == nil)
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
            let outcome = await BrowserReplPasteboardRedirect.shared.perform(
                "Paste",
                in: webView,
                pasteboard: tab,
                timeout: .seconds(1),
                systemChangeCount: tab.changeCount,
                whenWebKitFinishes: { finished = true }
            )
            #expect(outcome == .unavailable)
            #expect(finished)
            #expect(BrowserReplPasteboardRedirect.shared.redirectTarget(forLookupOf: general, fromWebKit: true) == nil)
        }

        private final class Terminations: NSObject, WKNavigationDelegate {
            var count = 0
            func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { count += 1 }
        }

        private static let slowPastePage = """
            <input id=i><script>
            addEventListener('paste', e => {
              const end = Date.now() + 1500;
              while (Date.now() < end) {}
              window.late = e.clipboardData.getData('text/plain');
            });
            </script>
            """

        /// A page that keeps its paste handler running past the timeout has
        /// its web content process ended at the timeout, so the handler
        /// never reads anything late and WebKit's default paste never runs.
        @Test func aPasteThatOutlivesTheTimeoutHasItsWebContentEnded() async throws {
            let standIn = Self.makeStandIn()
            defer { standIn.releaseGlobally() }
            let tab = NSPasteboard.withUniqueName()
            defer { tab.releaseGlobally() }
            tab.clearContents()
            tab.setString("tab text", forType: .string)
            let terminations = Terminations()
            var outcome: BrowserReplPasteboardRedirect.Outcome?
            try await Self.withStandInSystemPasteboard(standIn) {
                let webView = await load(Self.slowPastePage)
                _ = try await webView.evaluateJavaScript("document.getElementById('i').focus(); true")
                webView.navigationDelegate = terminations
                outcome = await BrowserReplPasteboardRedirect.shared.perform(
                    "Paste",
                    in: webView,
                    pasteboard: tab,
                    timeout: .milliseconds(300),
                    systemChangeCount: tab.changeCount + 1
                )
            }
            #expect(outcome == .timedOut)
            #expect(terminations.count == 1, "the page that outlived the paste's timeout kept its web content process")
            #expect(
                BrowserReplPasteboardRedirect.shared.redirectTarget(forLookupOf: general, fromWebKit: true) == nil,
                "the redirect outlived the paste's timeout"
            )
        }

        /// When the web content can no longer be ended at the timeout, the
        /// redirect stays until WebKit finishes: the handler's late read gets
        /// at most the tab's own clipboard, never the person's.
        @Test func aPasteWhoseWebContentCannotBeEndedReadsOnlyTheTabPasteboardLate() async throws {
            let standIn = NSPasteboard.withUniqueName()
            defer { standIn.releaseGlobally() }
            standIn.clearContents()
            standIn.setString("the person's clipboard", forType: .string)
            let tab = NSPasteboard.withUniqueName()
            defer { tab.releaseGlobally() }
            tab.clearContents()
            tab.setString("tab text", forType: .string)
            let systemBefore = NSPasteboard.general.changeCount
            var outcome: BrowserReplPasteboardRedirect.Outcome?
            var late: String?
            try await Self.withStandInSystemPasteboard(standIn) {
                let webView = await load(Self.slowPastePage)
                _ = try await webView.evaluateJavaScript("document.getElementById('i').focus(); true")
                var asked = 0
                let finished = BrowserReplLatch()
                outcome = await BrowserReplPasteboardRedirect.shared.perform(
                    "Paste",
                    in: webView,
                    pasteboard: tab,
                    timeout: .milliseconds(300),
                    grace: .seconds(600),
                    systemChangeCount: tab.changeCount + 1,
                    mayEndWebContent: {
                        asked += 1
                        return asked == 1
                    },
                    whenWebKitFinishes: { finished.signal() }
                )
                #expect(BrowserReplPasteboardRedirect.shared.redirectTarget(forLookupOf: general, fromWebKit: true) === tab)
                // The handler loops 1.5 s, but a loaded machine has run it
                // past 10 s; the bound only turns a hang into a failure.
                let clock = ContinuousClock()
                let webKitFinished = await finished.wait(until: clock.now.advanced(by: .seconds(300)), clock: clock)
                try #require(webKitFinished, "WebKit did not finish the paste within 300 s")
                late = try await webView.evaluateJavaScript("window.late ?? 'unset'") as? String
            }
            #expect(outcome == .timedOutStillRunning)
            #expect(BrowserReplPasteboardRedirect.shared.redirectTarget(forLookupOf: general, fromWebKit: true) == nil)
            // Bools, so a failure never prints the values.
            let readThePersonsClipboard = late == "the person's clipboard"
            #expect(!readThePersonsClipboard, "a paste handler that outlived the timeout read the system pasteboard")
            #expect(NSPasteboard.general.changeCount == systemBefore)
        }

        /// A command whose web content could not be ended at the timeout is
        /// ended one grace later regardless: the page's handler, still
        /// looping, never finishes, and the redirect ends.
        @Test func aPasteStillRunningAfterItsGraceHasItsWebContentEnded() async throws {
            let webView = await load(Self.slowPastePage)
            _ = try await webView.evaluateJavaScript("document.getElementById('i').focus(); true")
            let terminations = Terminations()
            webView.navigationDelegate = terminations
            let tab = NSPasteboard.withUniqueName()
            defer { tab.releaseGlobally() }
            tab.clearContents()
            tab.setString("tab text", forType: .string)
            var asked = 0
            let finished = BrowserReplLatch()
            let outcome = await BrowserReplPasteboardRedirect.shared.perform(
                "Paste",
                in: webView,
                pasteboard: tab,
                timeout: .milliseconds(200),
                grace: .milliseconds(200),
                systemChangeCount: tab.changeCount + 1,
                mayEndWebContent: {
                    asked += 1
                    return asked == 1
                },
                whenWebKitFinishes: { finished.signal() }
            )
            #expect(outcome == .timedOutStillRunning)
            let clock = ContinuousClock()
            let ended = await finished.wait(until: clock.now.advanced(by: .seconds(60)), clock: clock)
            try #require(ended, "the command was not ended within 60 s")
            #expect(terminations.count == 1, "the web content outlived the command's grace")
            #expect(asked == 2, "ending the web content after the grace asked the caller again")
            #expect(BrowserReplPasteboardRedirect.shared.redirectTarget(forLookupOf: general, fromWebKit: true) == nil)
        }

        /// Proof for WebKit's Copy and Cut of rich content (formatting, a
        /// link, an image): every write lands on the tab's pasteboard and
        /// none reaches the system pasteboard by any route, including
        /// `+[NSPasteboard generalPasteboard]`, which does not go through the
        /// `+pasteboardWithName:` lookup the redirect hooks.
        @Test(arguments: ["Copy", "Cut"])
        func webKitsCopyAndCutWriteOnlyTheTabPasteboard(command: String) async throws {
            let standIn = Self.makeStandIn()
            defer { standIn.releaseGlobally() }
            let standInBefore = standIn.changeCount
            let tab = NSPasteboard.withUniqueName()
            defer { tab.releaseGlobally() }
            tab.clearContents()
            let systemBefore = NSPasteboard.general.changeCount
            var outcome: BrowserReplPasteboardRedirect.Outcome?
            try await Self.withStandInSystemPasteboard(standIn) {
                let webView = await load(
                    """
                    <div id=ed contenteditable><b>bold</b> <a href="https://example.com/x">link</a> \
                    <img src="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="> text</div>
                    """
                )
                _ = try await webView.evaluateJavaScript(
                    "const ed = document.getElementById('ed'); ed.focus(); const r = document.createRange(); r.selectNodeContents(ed); getSelection().removeAllRanges(); getSelection().addRange(r); true"
                )
                outcome = await BrowserReplPasteboardRedirect.shared.perform(command, in: webView, pasteboard: tab, timeout: .seconds(10))
            }
            #expect(outcome == .completed)
            #expect(standIn.changeCount == standInBefore, "WebKit's \(command) wrote the system pasteboard")
            #expect(NSPasteboard.general.changeCount == systemBefore, "WebKit's \(command) wrote the real system pasteboard")
            let types = Set(tab.types ?? [])
            #expect(types.contains(.html), "WebKit's \(command) did not write its HTML to the tab's pasteboard")
            #expect(types.contains(.string), "WebKit's \(command) did not write its text to the tab's pasteboard")
            let copiedTheSelection = tab.string(forType: .string)?.contains("bold link") == true
            #expect(copiedTheSelection)
        }

        /// Editors (Google Docs, Notion, Monaco, CodeMirror) handle Copy and
        /// Cut themselves: their handler sets the event's data and cancels
        /// it. WebKit then writes the pasteboard from that data, which can be
        /// more than one change of the pasteboard. The command must still
        /// complete with the handler's data on the tab's pasteboard, and
        /// nothing may reach the system pasteboard.
        @Test(arguments: ["Copy", "Cut"])
        func aCopyOrCutWhoseHandlerSetsDataAndCancelsCompletesWithTheHandlersData(command: String) async throws {
            #expect(BrowserReplPasteboardRedirect.shared.install())
            let standIn = NSPasteboard.withUniqueName()
            defer { standIn.releaseGlobally() }
            standIn.clearContents()
            standIn.setString("the person's clipboard", forType: .string)
            let standInBefore = standIn.changeCount
            let systemBefore = NSPasteboard.general.changeCount
            var outcome: BrowserReplPasteboardRedirect.Outcome?
            var plain: String?
            var html: String?
            var custom: String?
            try await Self.withStandInSystemPasteboard(standIn) {
                let webView = await load(
                    """
                    <div id=ed contenteditable>editor text</div><script>
                    for (const type of ['copy', 'cut']) addEventListener(type, e => {
                      e.clipboardData.setData('text/plain', 'from the ' + type + ' handler');
                      e.clipboardData.setData('text/html', '<b>from the ' + type + ' handler</b>');
                      e.clipboardData.setData('application/x-editor', 'editor model');
                      e.preventDefault();
                    });
                    </script>
                    """
                )
                _ = try await webView.evaluateJavaScript(
                    "const ed = document.getElementById('ed'); ed.focus(); const r = document.createRange(); r.selectNodeContents(ed); getSelection().removeAllRanges(); getSelection().addRange(r); true"
                )
                let tab = NSPasteboard.withUniqueName()
                defer { tab.releaseGlobally() }
                tab.clearContents()
                outcome = await BrowserReplPasteboardRedirect.shared.perform(command, in: webView, pasteboard: tab, timeout: .seconds(10))
                plain = tab.string(forType: .string)
                html = tab.string(forType: .html)
                // WebKit keeps a page's custom types in its own blob type.
                custom = tab.data(forType: NSPasteboard.PasteboardType("com.apple.WebKit.custom-pasteboard-data"))
                    .map { String(decoding: $0, as: UTF8.self) }
            }
            #expect(outcome == .completed, "WebKit's \(command) with a handler that sets data and cancels did not complete")
            #expect(plain == "from the \(command.lowercased()) handler")
            #expect(html?.contains("from the \(command.lowercased()) handler") == true)
            #expect(custom?.contains("editor model") == true, "the handler's custom type did not reach the tab's clipboard")
            #expect(standIn.changeCount == standInBefore, "WebKit's \(command) wrote the system pasteboard")
            #expect(NSPasteboard.general.changeCount == systemBefore)
        }

        /// A page whose copy or cut handler runs past the timeout and only
        /// then sets its data (a hostile page planting a shell command for
        /// the person's next paste in the terminal). Nothing it writes may
        /// reach the system pasteboard, at any time.
        ///
        /// The system pasteboard is a stand-in here: every lookup of the
        /// general pasteboard by name that would reach the system's gets the
        /// stand-in, so a broken redirect fills the stand-in and the person's
        /// clipboard stays untouched. The real one is only read (its change
        /// count), which catches a write that bypasses the lookup.
        @Test(arguments: ["Copy", "Cut"])
        func aCopyOrCutThePageFinishesAfterTheTimeoutNeverReachesTheSystemPasteboard(command: String) async throws {
            #expect(BrowserReplPasteboardRedirect.shared.install())
            let standIn = NSPasteboard.withUniqueName()
            defer { standIn.releaseGlobally() }
            standIn.clearContents()
            standIn.setString("the person's clipboard", forType: .string)
            let standInBefore = standIn.changeCount
            let systemBefore = NSPasteboard.general.changeCount

            try await Self.withStandInSystemPasteboard(standIn) {
                let webView = await load(
                    """
                    <input id=i value="selected text"><script>
                    for (const type of ['copy', 'cut']) addEventListener(type, e => {
                      const end = Date.now() + 1500;
                      while (Date.now() < end) {}
                      e.clipboardData.setData('text/plain', 'planted by the page');
                      e.preventDefault();
                    });
                    </script>
                    """
                )
                _ = try await webView.evaluateJavaScript("const i = document.getElementById('i'); i.focus(); i.select(); true")
                let tab = NSPasteboard.withUniqueName()
                defer { tab.releaseGlobally() }
                tab.clearContents()
                let finished = BrowserReplLatch()
                let outcome = await BrowserReplPasteboardRedirect.shared.perform(
                    command,
                    in: webView,
                    pasteboard: tab,
                    timeout: .milliseconds(300),
                    whenWebKitFinishes: { finished.signal() }
                )
                #expect(outcome == .timedOut)
                // WebKit reports the command done (or its process ended) after
                // the page's writes on the same connection; one more round trip
                // to the page flushes anything after that.
                let clock = ContinuousClock()
                let webKitFinished = await finished.wait(until: clock.now.advanced(by: .seconds(300)), clock: clock)
                try #require(webKitFinished, "WebKit did not finish the command within 300 s")
                _ = try? await webView.evaluateJavaScript("0")
                let tabUntouched = tab.types?.isEmpty ?? true
                #expect(tabUntouched, "a write after the timeout landed on the tab's pasteboard")
            }

            #expect(standIn.changeCount == standInBefore, "the page's late \(command) wrote the system pasteboard")
            let kept = standIn.string(forType: .string) == "the person's clipboard"
            #expect(kept, "the page's late \(command) replaced the system pasteboard's contents")
            #expect(NSPasteboard.general.changeCount == systemBefore, "the page's late \(command) wrote the real system pasteboard")
        }

        /// WebKit's pasteboard requests do not say which web view they serve,
        /// so while a Copy runs, a copy in another web view (a person's, or a
        /// page's in a user's tab) also lands on the command's pasteboard.
        /// The tab's clipboard must not take that: WebKit's own Copy writes
        /// the pasteboard at most once, so a second write means another web
        /// view wrote it, and the command does not complete.
        @Test func aCopyInAnotherWebViewDuringACommandDoesNotReachTheTabClipboard() async throws {
            #expect(BrowserReplPasteboardRedirect.shared.install())
            let standIn = NSPasteboard.withUniqueName()
            defer { standIn.releaseGlobally() }
            standIn.clearContents()
            standIn.setString("the person's clipboard", forType: .string)
            let systemBefore = NSPasteboard.general.changeCount
            var outcome: BrowserReplPasteboardRedirect.Outcome?
            try await Self.withStandInSystemPasteboard(standIn) {
                let tabView = await load(
                    """
                    <input id=i value="tab text"><script>
                    addEventListener('copy', e => {
                      const end = Date.now() + 1000;
                      while (Date.now() < end) {}
                    });
                    </script>
                    """
                )
                _ = try await tabView.evaluateJavaScript("const i = document.getElementById('i'); i.focus(); i.select(); true")
                let otherView = await load("<input id=o value=\"another web view's text\">")
                _ = try await otherView.evaluateJavaScript("const o = document.getElementById('o'); o.focus(); o.select(); true")
                let tabProcess = tabView.value(forKey: "_webProcessIdentifier") as? Int
                let otherProcess = otherView.value(forKey: "_webProcessIdentifier") as? Int
                try #require(tabProcess != otherProcess, "the two web views share a web content process, so the other copy cannot run during the command")

                let tab = NSPasteboard.withUniqueName()
                defer { tab.releaseGlobally() }
                tab.clearContents()
                let command = Task { @MainActor in
                    await BrowserReplPasteboardRedirect.shared.perform("Copy", in: tabView, pasteboard: tab, timeout: .seconds(30))
                }
                while BrowserReplPasteboardRedirect.shared.redirectTarget(forLookupOf: general, fromWebKit: true) !== tab {
                    await Task.yield()
                }
                // The other web view copies while the tab's copy handler runs.
                // An evaluated script holds a user gesture, as a click would.
                let copied = try await otherView.evaluateJavaScript("document.execCommand('copy')") as? Bool
                try #require(copied == true)
                outcome = await command.value
            }
            #expect(outcome != .completed, "the tab's clipboard took a copy another web view made during the command")
            #expect(BrowserReplPasteboardRedirect.shared.redirectTarget(forLookupOf: general, fromWebKit: true) == nil)
            #expect(NSPasteboard.general.changeCount == systemBefore)
        }

        /// A person pasting in another web view while a tab's Paste runs
        /// (the tab's paste handler keeps the command in flight) must not
        /// read the tab's private pasteboard. WebKit grants a web content
        /// process read access when the app starts its Paste, at the change
        /// count the general pasteboard's lookup returns; during a command
        /// that lookup must not return the tab's pasteboard for any web view
        /// but the commanded one. The other view's paste is started from app
        /// code, as AppKit starts a person's Command-V or Edit menu Paste.
        @Test func aPasteInAnotherWebViewDuringACommandDoesNotReadTheTabPasteboard() async throws {
            #expect(BrowserReplPasteboardRedirect.shared.install())
            let standIn = Self.makeStandIn()
            defer { standIn.releaseGlobally() }
            let tab = NSPasteboard.withUniqueName()
            defer { tab.releaseGlobally() }
            tab.clearContents()
            tab.setString("tab text", forType: .string)
            let systemBefore = NSPasteboard.general.changeCount
            var outcome: BrowserReplPasteboardRedirect.Outcome?
            var otherValue: String?
            try await Self.withStandInSystemPasteboard(standIn) {
                let tabView = await load(
                    """
                    <input id=i><script>
                    addEventListener('paste', e => {
                      const end = Date.now() + 1000;
                      while (Date.now() < end) {}
                    });
                    </script>
                    """
                )
                _ = try await tabView.evaluateJavaScript("document.getElementById('i').focus(); true")
                let otherView = await load("<input id=o>")
                _ = try await otherView.evaluateJavaScript("document.getElementById('o').focus(); true")
                let tabProcess = tabView.value(forKey: "_webProcessIdentifier") as? Int
                let otherProcess = otherView.value(forKey: "_webProcessIdentifier") as? Int
                try #require(tabProcess != otherProcess, "the two web views share a web content process, so the other paste cannot run during the command")

                let command = Task { @MainActor in
                    await BrowserReplPasteboardRedirect.shared.perform(
                        "Paste",
                        in: tabView,
                        pasteboard: tab,
                        timeout: .seconds(30),
                        systemChangeCount: tab.changeCount + 1
                    )
                }
                while BrowserReplPasteboardRedirect.shared.redirectTarget(forLookupOf: general, fromWebKit: true) !== tab {
                    await Task.yield()
                }
                // The other web view's Paste starts while the tab's paste
                // handler runs. Its web content process handles the paste
                // before the script below, so the value read is the result.
                _ = otherView.perform(NSSelectorFromString("paste:"), with: nil)
                otherValue = try await otherView.evaluateJavaScript("document.getElementById('o').value") as? String
                outcome = await command.value
            }
            // A Bool, so a failure never prints the value.
            let readTheTabPasteboard = otherValue == "tab text"
            #expect(!readTheTabPasteboard, "a paste in another web view during the command read the tab's private pasteboard")
            #expect(outcome == .interfered, "the command completed as if no other web view had touched the pasteboard during it")
            #expect(BrowserReplPasteboardRedirect.shared.redirectTarget(forLookupOf: general, fromWebKit: true) == nil)
            #expect(NSPasteboard.general.changeCount == systemBefore)
        }

        /// Runs `body` with `standIn` in place of the system pasteboard for
        /// every lookup of the general pasteboard by name, the hook WebKit's
        /// pasteboard code uses. The redirect's own hook stays underneath and
        /// still answers first.
        /// A private pasteboard holding "the person's clipboard", to stand in
        /// for the system pasteboard.
        private static func makeStandIn() -> NSPasteboard {
            let standIn = NSPasteboard.withUniqueName()
            standIn.clearContents()
            standIn.setString("the person's clipboard", forType: .string)
            return standIn
        }

        /// Runs `body` with `standIn` for the system pasteboard: every lookup
        /// that would return the system's (`+pasteboardWithName:` with its
        /// name, past the redirect's hook, and `+generalPasteboard`) returns
        /// the stand-in, so a broken redirect never reads or writes the
        /// person's clipboard.
        private static func withStandInSystemPasteboard(
            _ standIn: NSPasteboard,
            _ body: () async throws -> Void
        ) async throws {
            let selector = NSSelectorFromString("pasteboardWithName:")
            let method = try #require(class_getClassMethod(NSPasteboard.self, selector))
            typealias Lookup = @convention(c) (AnyObject, Selector, NSString) -> NSPasteboard
            let previousImplementation = method_getImplementation(method)
            let previous = unsafeBitCast(previousImplementation, to: Lookup.self)
            let pasteboards = StandIn(system: NSPasteboard(name: .general), standIn: standIn)
            let replacement: @convention(block) @Sendable (AnyObject, NSString) -> NSPasteboard = { cls, name in
                let found = previous(cls, selector, name)
                return found === pasteboards.system ? pasteboards.standIn : found
            }
            let generalSelector = NSSelectorFromString("generalPasteboard")
            let generalMethod = try #require(class_getClassMethod(NSPasteboard.self, generalSelector))
            let previousGeneral = method_getImplementation(generalMethod)
            let generalReplacement: @convention(block) @Sendable (AnyObject) -> NSPasteboard = { _ in pasteboards.standIn }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
            method_setImplementation(generalMethod, imp_implementationWithBlock(generalReplacement))
            defer {
                method_setImplementation(generalMethod, previousGeneral)
                method_setImplementation(method, previousImplementation)
            }
            try await body()
        }

        private struct StandIn: @unchecked Sendable {
            let system: NSPasteboard
            let standIn: NSPasteboard
        }
    }
}

/// A clock that moves only when a test advances it.
final class ManualClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var sleepers: [Int: Sleeper] = [:]
    private var nextSleeper = 0

    var now: Instant { lock.withLock { current } }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = lock.withLock { () -> Int in
            nextSleeper += 1
            return nextSleeper
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let resumeNow: Bool = lock.withLock {
                    if deadline <= current { return true }
                    sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let sleeper = lock.withLock { sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        let due: [Sleeper] = lock.withLock {
            current = current.advanced(by: duration)
            let ids = sleepers.filter { $0.value.deadline <= current }.map(\.key)
            return ids.compactMap { sleepers.removeValue(forKey: $0) }
        }
        for sleeper in due { sleeper.continuation.resume() }
    }

    /// Waits until `count` sleeps are pending, for at most 30 s of real
    /// time, so code that never sleeps fails the test instead of hanging it.
    func waitForSleepers(_ count: Int) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < deadline {
            if lock.withLock({ sleepers.count }) >= count { return }
            await Task.yield()
        }
    }
}
