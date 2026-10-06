import AppKit
import Testing
import WebKit

@testable import CmuxBrowser

extension BrowserReplPasteboardTests {
    /// A user's tab has no page clipboard guard, and an agent's input or
    /// page-world script gives its page a user gesture. With that gesture
    /// WebKit lets a script paste (`execCommand("paste")`) or read
    /// `navigator.clipboard`: it asks the person with its own Paste menu,
    /// and grants it without asking when the clipboard holds data the same
    /// site copied. Agent code must never read the system clipboard, so
    /// script paste is off in the tab while an agent's input or page script
    /// runs there and while the page could still use the gesture it gave.
    ///
    /// The clipboard holds data the page's own site copied, the case WebKit
    /// grants without its menu: a leaking build reads it back silently and
    /// fails the test instead of opening a menu. The system pasteboard is a
    /// stand-in, so the person's clipboard stays untouched.
    ///
    /// A build where the refusal fails can open WebKit's Paste menu (a
    /// window) when the stand-in does not hold the same site's copy, so the
    /// suite runs only with `CMUX_BROWSER_REPL_PASTEBOARD_TESTS=1`, on a
    /// fleet Mac (cmux-lawrence-2), never on a laptop.
    @MainActor
    @Suite(
        "Script paste in a user's tab",
        .serialized,
        .enabled(
            if: ProcessInfo.processInfo.environment["CMUX_BROWSER_REPL_PASTEBOARD_TESTS"] == "1",
            "can open WebKit's Paste menu: run on cmux-lawrence-2 with CMUX_BROWSER_REPL_PASTEBOARD_TESTS=1"
        )
    )
    struct UserTabPaste {
        typealias PageScripts = BrowserReplPasteboardTests.PageScripts

        static let copied = "copied on the same site"

        /// A paste and a clipboard read, as an agent's page script or a
        /// page handler its input sets off would run them.
        static let read = """
            const field = document.getElementById('field');
            field.value = '';
            field.focus();
            const r = { paste: String(document.execCommand('paste')), pasted: field.value };
            try { r.readText = await navigator.clipboard.readText(); } catch (e) { r.readText = 'rejected ' + e.name; }
            return JSON.stringify(r);
            """

        static let refused = #"{"paste":"false","pasted":"","readText":"rejected NotAllowedError"}"#

        /// Reads that WebKit hands the gesture of the script that set them
        /// up (a timer, a promise chain, a fetch's callback): they run after
        /// the script returned.
        static let lateReads = """
            window.__late = {};
            const go = async (key) => {
              try { window.__late[key] = await navigator.clipboard.readText(); } catch (e) { window.__late[key] = 'rejected ' + e.name; }
            };
            setTimeout(() => go('timer'), 100);
            Promise.resolve().then(() => new Promise((resolve) => setTimeout(resolve, 200))).then(() => go('promise'));
            fetch('data:,x').then(() => go('fetch'), () => go('fetch'));
            return true;
            """

        /// A page with the person's same-site copy on the clipboard. Fails
        /// the test (before any read) when the copy did not land: a read of
        /// other data would open WebKit's Paste menu.
        private static func pageWithSameSiteCopy(_ standIn: NSPasteboard) async throws -> WKWebView {
            let page = try await PageScripts.load("<textarea id=field></textarea>") { _ in }
            _ = try await page.browserReplCallAsyncJavaScript(
                "await navigator.clipboard.writeText(text); return true",
                arguments: ["text": copied], in: nil, contentWorld: .page, userGesture: true
            )
            try #require(standIn.string(forType: .string) == copied)
            try #require(standIn.types?.contains(NSPasteboard.PasteboardType("com.apple.WebKit.custom-pasteboard-data")) == true)
            return page
        }

        private static func run(_ script: String, in page: WKWebView) async throws -> String? {
            try await page.browserReplCallAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page, userGesture: true) as? String
        }

        @Test("An agent's page script in a user's tab cannot paste or read the clipboard, also after it returns")
        func agentScriptCannotReadTheClipboard() async throws {
            var during: String?
            var late: [String: String] = [:]
            var afterLingering: String?
            let clock = ManualClock()
            try await PageScripts.withStandInSystemPasteboard { standIn in
                let page = try await Self.pageWithSameSiteCopy(standIn)
                let hold = try #require(BrowserReplPageClipboard.holdScriptPasteOff(
                    in: page, sleeper: BrowserReplClockSleeper(clock: clock), lingering: .seconds(11)
                ))
                during = try await Self.run(Self.read, in: page)
                _ = try await page.browserReplCallAsyncJavaScript(Self.lateReads, arguments: [:], in: nil, contentWorld: .page, userGesture: true)
                hold.release()
                try await PageScripts.settle({ false }) {
                    late = try await page.callAsyncJavaScript("return window.__late", arguments: [:], in: nil, contentWorld: .page) as? [String: String] ?? [:]
                    return late.count == 3
                }
                // Once the page can no longer use the gesture, the page's own
                // script paste (a person's click on its Paste button) works again.
                clock.advance(by: .seconds(11))
                try await PageScripts.settle({ false }) {
                    afterLingering = try await Self.run(Self.read, in: page)
                    return afterLingering != Self.refused
                }
            }
            #expect(during == Self.refused, "an agent's page script read the clipboard")
            #expect(late == ["timer": "rejected NotAllowedError", "promise": "rejected NotAllowedError", "fetch": "rejected NotAllowedError"], "a read the agent's script set up read the clipboard after it returned")
            #expect(afterLingering == #"{"paste":"true","pasted":"\#(Self.copied)","readText":"\#(Self.copied)"}"#, "script paste did not come back after the hold")
        }

        @Test("Script paste stays off while another hold on the tab lasts")
        func overlappingHoldsKeepScriptPasteOff() async throws {
            var whileOtherHolds: String?
            let clock = ManualClock()
            try await PageScripts.withStandInSystemPasteboard { standIn in
                let page = try await Self.pageWithSameSiteCopy(standIn)
                let sleeper = BrowserReplClockSleeper(clock: clock)
                let first = try #require(BrowserReplPageClipboard.holdScriptPasteOff(in: page, sleeper: sleeper, lingering: .seconds(11)))
                let second = try #require(BrowserReplPageClipboard.holdScriptPasteOff(in: page, sleeper: sleeper, lingering: .seconds(11)))
                first.release()
                clock.advance(by: .seconds(60))
                whileOtherHolds = try await Self.run(Self.read, in: page)
                second.release()
            }
            #expect(whileOtherHolds == Self.refused, "script paste came back while another session's input held it off")
        }

        /// The page clipboard guard of a tab a session created turns script
        /// paste off for the web view's life
        /// (``BrowserReplPageClipboard/install(on:refusing:onWrite:)``); a
        /// hold there must not turn it back on when it ends. The engine
        /// switch is set here without the guard's page script, which would
        /// answer the reads itself.
        @Test("A hold's end leaves script paste off where it was off before")
        func holdKeepsAnEarlierRefusal() async throws {
            var afterHold: String?
            let clock = ManualClock()
            try await PageScripts.withStandInSystemPasteboard { standIn in
                let page = try await Self.pageWithSameSiteCopy(standIn)
                try #require(BrowserReplPageClipboard.disableAsyncClipboardAPI(in: page.configuration.preferences, featureKey: "DOMPasteAccessRequestsEnabled"))
                let hold = try #require(BrowserReplPageClipboard.holdScriptPasteOff(in: page, sleeper: BrowserReplClockSleeper(clock: clock), lingering: .seconds(11)))
                hold.release()
                await clock.waitForSleepers(1)
                clock.advance(by: .seconds(11))
                // The hold's end runs on the main actor once the clock wakes it.
                await clock.waitForSleepers(0)
                await Task.yield()
                afterHold = try await Self.run(Self.read, in: page)
            }
            #expect(afterHold == Self.refused, "a hold's end turned script paste back on where the guard had it off")
        }
    }
}
