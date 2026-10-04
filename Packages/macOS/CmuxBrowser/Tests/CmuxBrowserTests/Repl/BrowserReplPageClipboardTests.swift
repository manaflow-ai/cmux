import AppKit
import ObjectiveC
import WebKit
import Testing

@testable import CmuxBrowser

extension BrowserReplPasteboardRedirectTests {
    /// Page scripts in a tab a REPL session created (the Clipboard API, a
    /// `ClipboardItem` whose data arrives later, `execCommand("copy")`) must
    /// never write the system clipboard, at any time: an agent's click gives
    /// the page a user gesture, and a hostile page could plant a shell command
    /// for the person's next paste in the terminal. Their writes land on the
    /// tab's own clipboard instead. A tab no session created keeps the
    /// browser's behavior.
    ///
    /// The system pasteboard is a stand-in for every lookup WebKit makes of
    /// it (by name, and `+generalPasteboard`, which the asynchronous Clipboard
    /// API uses, also off the main thread), so a leaking build fills the
    /// stand-in and the person's clipboard stays untouched. The real one is
    /// only read (its change count).
    ///
    /// Nested in the redirect suite: the stand-in replaces process-wide
    /// lookups, so these tests must not run alongside the redirect's.
    @MainActor
    @Suite("Page scripts", .serialized)
    struct PageScripts {
        /// Each page action runs from a click handler: the click runs in a
        /// user gesture (WebKit grants one to a script the app evaluates, as
        /// it does to an agent's real click).
        static let page = """
            <input id=field value="copied by execCommand">
            <button id=write-text>write text</button>
            <button id=write-item>write a late item</button>
            <button id=exec-copy>execCommand copy</button>
            <button id=exec-copy-handler>execCommand copy with a handler</button>
            <button id=write-held>write an item whose data the page releases later</button>
            <script>
            const done = (value) => { window.__done = value; };
            const failed = (e) => done('rejected ' + (e && e.name));
            document.getElementById('write-text').onclick = () => {
              navigator.clipboard.writeText('planted by writeText').then(() => done('ok'), failed);
            };
            document.getElementById('write-item').onclick = () => {
              const late = new Promise((resolve) => setTimeout(() => resolve(new Blob(['planted by a late item'], { type: 'text/plain' })), 300));
              navigator.clipboard.write([new ClipboardItem({ 'text/plain': late })]).then(() => done('ok'), failed);
            };
            document.getElementById('write-held').onclick = () => {
              const held = new Promise((resolve) => {
                window.__release = () => resolve(new Blob(['planted by a held item'], { type: 'text/plain' }));
              });
              navigator.clipboard.write([new ClipboardItem({ 'text/plain': held })]).then(() => done('ok'), failed);
            };
            document.getElementById('exec-copy').onclick = () => {
              const field = document.getElementById('field');
              field.focus();
              field.select();
              done(String(document.execCommand('copy')));
            };
            document.getElementById('exec-copy-handler').onclick = () => {
              document.addEventListener('copy', (e) => {
                e.clipboardData.setData('text/plain', 'planted by a copy handler');
                e.preventDefault();
              }, { once: true });
              done(String(document.execCommand('copy')));
            };
            </script>
            """

        struct Case: CustomTestStringConvertible, Sendable {
            let button: String
            let done: String
            let text: String
            var testDescription: String { button }
        }

        nonisolated static let cases: [Case] = [
            Case(button: "write-text", done: "ok", text: "planted by writeText"),
            Case(button: "write-item", done: "ok", text: "planted by a late item"),
            Case(button: "exec-copy", done: "true", text: "copied by execCommand"),
            Case(button: "exec-copy-handler", done: "true", text: "planted by a copy handler"),
        ]

        @Test(arguments: cases)
        func aPageScriptInASessionTabWritesOnlyTheTabClipboard(_ action: Case) async throws {
            let shim = try Self.shim()
            let system = NSPasteboard.general
            let systemBefore = system.changeCount
            var routed: [[[String: Any]]] = []
            var outcome: (done: String?, standInChanged: Bool, standInKept: Bool)?
            try await Self.withStandInSystemPasteboard { standIn in
                let standInBefore = standIn.changeCount
                let webView = try await Self.load(Self.page) { webView in
                    BrowserReplPageClipboard(shim: shim).install(on: webView) { _, items in
                        routed.append(items)
                        return true
                    }
                }
                try await Self.click(action.button, in: webView)
                let done = try await Self.waitForDone(in: webView)
                // Let a write that would land late (WebKit's or the routed
                // one) arrive before judging.
                try await Self.settle { !routed.isEmpty || standIn.changeCount != standInBefore }
                outcome = (
                    done,
                    standIn.changeCount != standInBefore,
                    standIn.string(forType: .string) == Self.personsClipboard
                )
            }
            let result = try #require(outcome)
            #expect(!result.standInChanged, "the page's \(action.button) wrote the system pasteboard")
            #expect(result.standInKept, "the page's \(action.button) replaced the system pasteboard's contents")
            #expect(system.changeCount == systemBefore, "the page's \(action.button) wrote the real system pasteboard")
            #expect(result.done == action.done)
            let texts = routed.last?.compactMap { item -> String? in
                guard item["type"] as? String == "text/plain",
                      let base64 = item["base64"] as? String,
                      let data = Data(base64Encoded: base64) else { return nil }
                return String(decoding: data, as: UTF8.self)
            }
            #expect(routed.count == 1, "the tab's clipboard did not get exactly one write")
            #expect(texts == [action.text])
        }

        /// The guard's first half is WebKit's own switch for the asynchronous
        /// Clipboard API; the page script cannot reach a frame's initial empty
        /// document, so without the switch such a document keeps a native
        /// `navigator.clipboard` that writes the system clipboard. A WebKit
        /// without the switch has no guard at all: the driver opens no
        /// session tab there (`tabs.open` fails with `unsupported`).
        @Test func theGuardIsSupportedOnlyWhereWebKitCanTurnTheClipboardAPIOff() {
            #expect(BrowserReplPageClipboard.isSupported, "this WebKit can turn its asynchronous Clipboard API off")
            #expect(
                !BrowserReplPageClipboard.isSupported(featureKey: "CmuxNoSuchWebKitFeature"),
                "a WebKit without the switch was reported as guarded"
            )
            let preferences = WKPreferences()
            #expect(!BrowserReplPageClipboard.disableAsyncClipboardAPI(in: preferences, featureKey: "CmuxNoSuchWebKitFeature"))
        }

        /// In the app an agent's click reaches the page's click handler after
        /// WebKit has reset the page's transient activation (it does after
        /// each script the driver evaluates between the press and the
        /// release), so `navigator.userActivation.isActive` is false there
        /// although the click is a user gesture. The page's write still lands
        /// on the tab's clipboard. Here the click runs from a script WebKit
        /// evaluates without a user gesture, which leaves the page in the same
        /// state.
        @Test(arguments: [cases[0], cases[2]])
        func aPageScriptWithoutTransientActivationStillWritesTheTabClipboard(_ action: Case) async throws {
            let shim = try Self.shim()
            var routed: [[[String: Any]]] = []
            var outcome: (done: String?, active: String?, standInChanged: Bool)?
            try await Self.withStandInSystemPasteboard { standIn in
                let standInBefore = standIn.changeCount
                let webView = try await Self.load(Self.page) { webView in
                    BrowserReplPageClipboard(shim: shim).install(on: webView) { _, items in
                        routed.append(items)
                        return true
                    }
                }
                let selector = NSSelectorFromString("_evaluateJavaScriptWithoutUserGesture:completionHandler:")
                try #require(webView.responds(to: selector))
                typealias Evaluate = @convention(c) (AnyObject, Selector, NSString, (@convention(block) (Any?, (any Error)?) -> Void)?) -> Void
                let evaluate = unsafeBitCast(webView.method(for: selector), to: Evaluate.self)
                var active: String?
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let script = "window.__active = String(navigator.userActivation.isActive); document.getElementById('\(action.button)').click(); window.__active"
                    evaluate(webView, selector, script as NSString) { value, _ in
                        active = value as? String
                        continuation.resume()
                    }
                }
                let done = try await Self.waitForDone(in: webView)
                try await Self.settle { !routed.isEmpty || standIn.changeCount != standInBefore }
                outcome = (done, active, standIn.changeCount != standInBefore)
            }
            let result = try #require(outcome)
            #expect(result.active == "false", "the click ran with transient activation, so this tests nothing")
            #expect(!result.standInChanged, "the page's \(action.button) wrote the system pasteboard")
            #expect(result.done == action.done)
            let texts = routed.last?.compactMap { item -> String? in
                guard let base64 = item["base64"] as? String, let data = Data(base64Encoded: base64) else { return nil }
                return String(decoding: data, as: UTF8.self)
            }
            #expect(texts == [action.text], "the page's write did not reach the tab's clipboard")
        }

        /// A tab no session created keeps the browser's behavior: the page's
        /// writes reach the (stand-in) system pasteboard, also after a session
        /// tab in this process installed the guard.
        @Test func aPageScriptInATabNoSessionCreatedStillWritesTheSystemPasteboard() async throws {
            let shim = try Self.shim()
            let system = NSPasteboard.general
            let systemBefore = system.changeCount
            var written: [String?] = []
            try await Self.withStandInSystemPasteboard { standIn in
                _ = try await Self.load(Self.page) { webView in
                    BrowserReplPageClipboard(shim: shim).install(on: webView) { _, _ in true }
                }
                let webView = try await Self.load(Self.page) { _ in }
                for button in ["write-text", "exec-copy"] {
                    try await Self.click(button, in: webView)
                    _ = try await Self.waitForDone(in: webView)
                    try await Self.settle { standIn.string(forType: .string) != Self.personsClipboard }
                    written.append(standIn.string(forType: .string))
                    standIn.clearContents()
                    standIn.setString(Self.personsClipboard, forType: .string)
                    _ = try await webView.callAsyncJavaScript("delete window.__done", arguments: [:], in: nil, contentWorld: .page)
                }
            }
            #expect(written == ["planted by writeText", "copied by execCommand"])
            #expect(system.changeCount == systemBefore, "the stand-in let a write reach the real system pasteboard")
        }

        // MARK: - Helpers

        static let personsClipboard = "the person's clipboard"

        /// `Resources/browser-repl/page-clipboard.js`, the script the app
        /// installs in a session's tabs.
        static func shim() throws -> String {
            var url = URL(fileURLWithPath: #filePath)
            while url.path != "/" && !FileManager.default.fileExists(atPath: url.appendingPathComponent("Resources/browser-repl").path) {
                url.deleteLastPathComponent()
            }
            return try String(contentsOf: url.appendingPathComponent("Resources/browser-repl/page-clipboard.js"), encoding: .utf8)
        }

        private final class Loaded: NSObject, WKNavigationDelegate {
            var continuation: CheckedContinuation<Void, Never>?
            func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
                continuation?.resume()
                continuation = nil
            }
        }

        static func load(_ html: String, prepare: (WKWebView) -> Void) async throws -> WKWebView {
            let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: WKWebViewConfiguration())
            prepare(webView)
            let loaded = Loaded()
            webView.navigationDelegate = loaded
            await withCheckedContinuation { continuation in
                loaded.continuation = continuation
                webView.loadHTMLString(html, baseURL: URL(string: "https://example.com/"))
            }
            webView.navigationDelegate = nil
            return webView
        }

        static func click(_ id: String, in webView: WKWebView) async throws {
            _ = try await webView.callAsyncJavaScript(
                "document.getElementById(id).click(); return true",
                arguments: ["id": id],
                in: nil,
                contentWorld: .page
            )
        }

        /// What the page's handler reported once its write settled.
        static func waitForDone(in webView: WKWebView) async throws -> String? {
            var done: String?
            try await settle {
                false
            } poll: {
                done = try await webView.callAsyncJavaScript(
                    "return window.__done ?? null",
                    arguments: [:],
                    in: nil,
                    contentWorld: .page
                ) as? String
                return done != nil
            }
            return done
        }

        /// Waits until `condition`, or `poll`, holds, for at most 30 s. The
        /// bound only turns a broken build into a failure instead of a hang;
        /// on a loaded machine a 300 ms page timer has taken seconds.
        static func settle(
            _ condition: @MainActor () -> Bool,
            poll: @MainActor () async throws -> Bool = { false }
        ) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            while ContinuousClock.now < deadline {
                if condition() { return }
                if try await poll() { return }
                try await Task.sleep(for: .milliseconds(50))
            }
        }

        /// Runs `body` with a stand-in for the system pasteboard: every lookup
        /// that would return the system's (`+pasteboardWithName:` with its
        /// name, and `+generalPasteboard`) returns the stand-in, which starts
        /// with ``personsClipboard``.
        static func withStandInSystemPasteboard(_ body: (NSPasteboard) async throws -> Void) async throws {
            let standIn = NSPasteboard.withUniqueName()
            defer { standIn.releaseGlobally() }
            standIn.clearContents()
            standIn.setString(personsClipboard, forType: .string)
            let pasteboards = StandIn(system: NSPasteboard(name: .general), standIn: standIn)

            let byName = NSSelectorFromString("pasteboardWithName:")
            let byNameMethod = try #require(class_getClassMethod(NSPasteboard.self, byName))
            typealias Lookup = @convention(c) (AnyObject, Selector, NSString) -> NSPasteboard
            let previousByName = method_getImplementation(byNameMethod)
            let lookUp = unsafeBitCast(previousByName, to: Lookup.self)
            let byNameReplacement: @convention(block) @Sendable (AnyObject, NSString) -> NSPasteboard = { cls, name in
                let found = lookUp(cls, byName, name)
                return found === pasteboards.system ? pasteboards.standIn : found
            }

            let general = NSSelectorFromString("generalPasteboard")
            let generalMethod = try #require(class_getClassMethod(NSPasteboard.self, general))
            let previousGeneral = method_getImplementation(generalMethod)
            let generalReplacement: @convention(block) @Sendable (AnyObject) -> NSPasteboard = { _ in pasteboards.standIn }

            method_setImplementation(byNameMethod, imp_implementationWithBlock(byNameReplacement))
            method_setImplementation(generalMethod, imp_implementationWithBlock(generalReplacement))
            defer {
                method_setImplementation(generalMethod, previousGeneral)
                method_setImplementation(byNameMethod, previousByName)
            }
            try await body(standIn)
        }

        private struct StandIn: @unchecked Sendable {
            let system: NSPasteboard
            let standIn: NSPasteboard
        }
    }
}
