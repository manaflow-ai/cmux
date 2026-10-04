import AppKit
import ObjectiveC
import Testing
import WebKit

@testable import CmuxBrowser

extension BrowserReplPasteboardRedirectTests {
    /// An agent's click, key or page-world script gives the page a user
    /// gesture, and a page holding one may write the system clipboard
    /// (`execCommand("copy")`, the asynchronous Clipboard API). In a user's
    /// tab no page clipboard guard is installed, so while the agent's call
    /// is in flight, and while WebKit still honors the gesture it gave,
    /// WebKit's own writes of the general pasteboard are quarantined: they
    /// reach a private pasteboard that is emptied at every lookup. Script in
    /// the agent's own world runs without a user gesture at all.
    ///
    /// The system pasteboard is a stand-in (both lookups WebKit makes), so a
    /// leaking build fills the stand-in and the person's clipboard stays
    /// untouched. Nested in the redirect suite: the redirect and the
    /// stand-in replace process-wide lookups.
    @MainActor
    @Suite("Agent gestures", .serialized)
    struct AgentGestures {
        typealias PageScripts = BrowserReplPasteboardRedirectTests.PageScripts

        private static func reset(_ webView: WKWebView) async throws {
            _ = try await webView.callAsyncJavaScript("delete window.__done; return true", arguments: [:], in: nil, contentWorld: .page)
        }

        @Test("A page's clipboard writes in an agent's gesture never reach the system pasteboard while the quarantine holds")
        func writesDuringTheQuarantineAreDropped() async throws {
            let redirect = BrowserReplPasteboardRedirect.shared
            #expect(redirect.install())
            var written: [Bool] = []
            var lingered: [Bool] = []
            try await Self.withStandInSystemPasteboard { standIn in
                let webView = try await PageScripts.load(PageScripts.page) { _ in }
                #expect(redirect.beginQuarantine())
                let quarantine = try #require(redirect.quarantinePasteboard)
                // WebKit's write lands on the stand-in, or (quarantined) on the
                // private pasteboard, which every lookup empties.
                let landed = { (before: Int, quarantined: Int) in
                    standIn.changeCount != before || quarantine.changeCount != quarantined
                }
                for button in ["exec-copy", "write-text"] {
                    let before = standIn.changeCount
                    let quarantined = quarantine.changeCount
                    try await PageScripts.click(button, in: webView)
                    _ = try await PageScripts.waitForDone(in: webView)
                    try await PageScripts.settle { landed(before, quarantined) }
                    written.append(standIn.changeCount != before || standIn.string(forType: .string) != PageScripts.personsClipboard)
                    try await Self.reset(webView)
                }
                // WebKit honors a gesture for a while after the call (up to
                // 10 s through a fetch), so the quarantine lingers.
                redirect.endQuarantine(lingering: .seconds(120))
                let before = standIn.changeCount
                let quarantined = quarantine.changeCount
                try await PageScripts.click("exec-copy", in: webView)
                _ = try await PageScripts.waitForDone(in: webView)
                try await PageScripts.settle { landed(before, quarantined) }
                lingered.append(standIn.changeCount != before)
                try await Self.reset(webView)
            }
            redirect.liftQuarantine()
            #expect(written == [false, false], "a page's write in the agent's gesture reached the system pasteboard: \(written)")
            #expect(lingered == [false], "a page's write reached the system pasteboard while the quarantine lingered")
        }

        /// The asynchronous Clipboard API takes a `ClipboardItem` whose data
        /// is a promise: the page calls `navigator.clipboard.write` in the
        /// agent's gesture, and WebKit writes when the data settles, which the
        /// page can hold past the quarantine. WebKit writes only when the
        /// general pasteboard's change count is the one it read when the
        /// page called `write`, which in the quarantine is the private
        /// pasteboard's; so the write stays quarantined however late its
        /// data arrives only when the system pasteboard can never show that
        /// count. The test plays the worst case: the private pasteboard has
        /// seen more changes than the system's (lookups empty it, so its
        /// count grows), and after the quarantine the system's count is
        /// raised to the one the page read, as copies the person makes would.
        @Test("A clipboard write the page started in an agent's gesture stays quarantined however late its data arrives")
        func aWriteStartedInTheQuarantineStaysQuarantinedWhenItsDataArrivesLater() async throws {
            let redirect = BrowserReplPasteboardRedirect.shared
            #expect(redirect.install())
            var done: String?
            var written = false
            try await Self.withStandInSystemPasteboard { standIn in
                let webView = try await PageScripts.load(PageScripts.page) { _ in }
                #expect(redirect.beginQuarantine())
                let earlier = try #require(redirect.quarantinePasteboard)
                while earlier.changeCount <= standIn.changeCount + 10 { earlier.clearContents() }
                // The agent's click: the page starts its write in the gesture.
                try await PageScripts.click("write-held", in: webView)
                let seen = redirect.quarantinePasteboard?.changeCount ?? 0
                redirect.endQuarantine(lingering: .zero)
                // The quarantine is over. The system pasteboard's count
                // reaches the one the page read, then the page releases the
                // data.
                while standIn.changeCount < seen - 1 { standIn.clearContents() }
                standIn.clearContents()
                standIn.setString(PageScripts.personsClipboard, forType: .string)
                _ = try await webView.callAsyncJavaScript("window.__release(); return true", arguments: [:], in: nil, contentWorld: .page)
                done = try await PageScripts.waitForDone(in: webView)
                written = standIn.string(forType: .string) != PageScripts.personsClipboard
            }
            redirect.liftQuarantine()
            #expect(done != nil, "the page's write never settled")
            #expect(!written, "a write the page started in the agent's gesture reached the system pasteboard once its data arrived after the quarantine")
        }

        @Test("Once the quarantine is over, a page's clipboard writes reach the system pasteboard as in a browser")
        func writesAfterTheQuarantineReachTheSystemPasteboard() async throws {
            let redirect = BrowserReplPasteboardRedirect.shared
            #expect(redirect.install())
            var text: String?
            try await Self.withStandInSystemPasteboard { standIn in
                let webView = try await PageScripts.load(PageScripts.page) { _ in }
                #expect(redirect.beginQuarantine())
                redirect.endQuarantine(lingering: .zero)
                try await PageScripts.click("exec-copy", in: webView)
                _ = try await PageScripts.waitForDone(in: webView)
                try await PageScripts.settle { standIn.string(forType: .string) != PageScripts.personsClipboard }
                text = standIn.string(forType: .string)
            }
            #expect(text == "copied by execCommand")
        }

        @Test("Script the agent runs in its own world gets no user gesture, so it cannot copy")
        func agentWorldScriptCannotCopy() async throws {
            var result: Any?
            var written = false
            try await Self.withStandInSystemPasteboard { standIn in
                let before = standIn.changeCount
                let page = try await PageScripts.load(PageScripts.page) { _ in }
                let gate = BrowserReplFrameGate(world: .world(name: "cmux-agent-gesture-tests-driver"), loadHold: BrowserReplSubframeLoadHold())
                let main = BrowserReplFrame(frameID: "main", parentFrameID: nil, indexInParent: 0, info: nil, url: "", name: "", crossOrigin: false)
                result = try await gate.callAsyncJavaScript(
                    "const f = document.getElementById('field'); f.focus(); f.select(); return String(document.execCommand('copy'))",
                    arguments: [:],
                    in: page,
                    frame: main,
                    contentWorld: .world(name: "cmux-agent-gesture-tests-agent"),
                    userGesture: false
                )
                // A copy WebKit ran writes the pasteboard before execCommand returns.
                written = standIn.changeCount != before
            }
            #expect(result as? String == "false", "the agent world's execCommand(\"copy\") ran in a user gesture")
            #expect(!written, "script in the agent's world wrote the system pasteboard")
        }

        /// The driver's own scripts (the frame gate's probes and the scripts
        /// it runs through the gate, the capture mask's, the secret target's)
        /// read the page from a content world, where code (the agent's, in
        /// the agent's world) can have replaced a getter they call. They must
        /// run without a user gesture, or that code could copy, or let a
        /// page handler copy or open a window.
        @Test("The driver's probes and gated scripts run without a user gesture")
        func driverScriptsRunWithoutAUserGesture() async throws {
            var seen: [String: [String: Any]] = [:]
            var written = false
            try await Self.withStandInSystemPasteboard { standIn in
                let before = standIn.changeCount
                let page = try await PageScripts.load(PageScripts.page) { _ in }
                let world = WKContentWorld.world(name: "cmux-agent-gesture-tests-patched")
                // Code in the world replaces a getter the scripts read.
                _ = try await page.browserReplCallAsyncJavaScript(
                    """
                    const field = document.getElementById('field');
                    Object.defineProperty(Document.prototype, 'title', {
                      configurable: true,
                      get() {
                        globalThis.__active = navigator.userActivation.isActive;
                        field.focus();
                        field.select();
                        globalThis.__copied = document.execCommand('copy');
                        return 'patched';
                      },
                    });
                    return true;
                    """,
                    arguments: [:],
                    in: nil,
                    contentWorld: world,
                    userGesture: false
                )
                let read = { () async throws -> [String: Any] in
                    let value = try await page.browserReplCallAsyncJavaScript(
                        "const r = { active: globalThis.__active, copied: globalThis.__copied }; delete globalThis.__active; delete globalThis.__copied; return r;",
                        arguments: [:],
                        in: nil,
                        contentWorld: world,
                        userGesture: false
                    )
                    return value as? [String: Any] ?? [:]
                }
                _ = try await BrowserReplScriptProbe().call("return document.title", arguments: [:], in: page, frame: nil, contentWorld: world, what: "the page")
                seen["probe"] = try await read()
                let gate = BrowserReplFrameGate(world: .world(name: "cmux-agent-gesture-tests-gate"), loadHold: BrowserReplSubframeLoadHold())
                let main = BrowserReplFrame(frameID: "main", parentFrameID: nil, indexInParent: 0, info: nil, url: "", name: "", crossOrigin: false)
                _ = try await gate.callAsyncJavaScript("return document.title", arguments: [:], in: page, frame: main, contentWorld: world)
                seen["gate"] = try await read()
                written = standIn.changeCount != before
            }
            for (path, record) in seen.sorted(by: { $0.key < $1.key }) {
                #expect(record["active"] as? Bool == false, "a script run through \(path) held a user gesture")
                #expect(record["copied"] as? Bool == false, "a script run through \(path) could copy")
            }
            #expect(seen.count == 2)
            #expect(!written, "a driver script wrote the system pasteboard")
        }

        /// A tab a session created has the page clipboard guard in the page's
        /// world only. Code in the agent's world (a listener it registered,
        /// a getter it replaced) keeps WebKit's own `execCommand`, and an
        /// agent's click or page script that later sets it off gives it a
        /// user gesture. So the agent's gesture quarantines WebKit's writes
        /// in that tab too.
        @Test("An agent-world listener cannot copy with the gesture of an agent's click in a guarded tab")
        func agentWorldListenerCannotCopyInAGuardedTab() async throws {
            let redirect = BrowserReplPasteboardRedirect.shared
            #expect(redirect.install())
            let shim = try PageScripts.shim()
            var copied: Any?
            var written = false
            try await Self.withStandInSystemPasteboard { standIn in
                let page = try await PageScripts.load(PageScripts.page) { webView in
                    BrowserReplPageClipboard(shim: shim).install(on: webView) { _, _ in true }
                }
                let world = WKContentWorld.world(name: "cmux-agent-gesture-tests-listener")
                _ = try await page.browserReplCallAsyncJavaScript(
                    """
                    const field = document.getElementById('field');
                    document.getElementById('write-text').addEventListener('click', () => {
                      field.focus();
                      field.select();
                      globalThis.__copied = document.execCommand('copy');
                    });
                    return true;
                    """,
                    arguments: [:],
                    in: nil,
                    contentWorld: world,
                    userGesture: false
                )
                let before = standIn.changeCount
                let quarantined = redirect.quarantinePasteboard?.changeCount
                // The agent's click, as the driver runs it.
                try await redirect.withAgentGesture(lingering: .zero) {
                    try await PageScripts.click("write-text", in: page)
                }
                copied = try await page.browserReplCallAsyncJavaScript("return globalThis.__copied ?? null", arguments: [:], in: nil, contentWorld: world, userGesture: false)
                // WebKit's write lands on the stand-in, or (quarantined) on the
                // private pasteboard.
                try await PageScripts.settle {
                    standIn.changeCount != before || redirect.quarantinePasteboard?.changeCount != quarantined
                }
                written = standIn.changeCount != before || standIn.string(forType: .string) != PageScripts.personsClipboard
            }
            redirect.liftQuarantine()
            #expect(copied as? Bool == true, "the listener did not run in the click's gesture, so the test proves nothing")
            #expect(!written, "an agent-world listener wrote the system pasteboard with the gesture of the agent's click")
        }

        /// Like ``PageScripts/withStandInSystemPasteboard(_:)``, but the
        /// stand-in replaces only what the lookups in place (the redirect's)
        /// would return for the system pasteboard, so the redirect still
        /// answers both lookups.
        static func withStandInSystemPasteboard(_ body: (NSPasteboard) async throws -> Void) async throws {
            let standIn = NSPasteboard.withUniqueName()
            defer { standIn.releaseGlobally() }
            standIn.clearContents()
            standIn.setString(PageScripts.personsClipboard, forType: .string)
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
            typealias General = @convention(c) (AnyObject, Selector) -> NSPasteboard
            let previousGeneral = method_getImplementation(generalMethod)
            let generalLookUp = unsafeBitCast(previousGeneral, to: General.self)
            let generalReplacement: @convention(block) @Sendable (AnyObject) -> NSPasteboard = { cls in
                let found = generalLookUp(cls, general)
                return found === pasteboards.system ? pasteboards.standIn : found
            }

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
