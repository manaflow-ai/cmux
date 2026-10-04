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
                for button in ["exec-copy", "write-text"] {
                    let before = standIn.changeCount
                    try await PageScripts.click(button, in: webView)
                    _ = try await PageScripts.waitForDone(in: webView)
                    try await PageScripts.settle { standIn.changeCount != before }
                    written.append(standIn.changeCount != before || standIn.string(forType: .string) != PageScripts.personsClipboard)
                    try await Self.reset(webView)
                }
                // WebKit honors a gesture for a while after the call (up to
                // 10 s through a fetch), so the quarantine lingers.
                redirect.endQuarantine(lingering: .seconds(120))
                let before = standIn.changeCount
                try await PageScripts.click("exec-copy", in: webView)
                _ = try await PageScripts.waitForDone(in: webView)
                try await PageScripts.settle { standIn.changeCount != before }
                lingered.append(standIn.changeCount != before)
                try await Self.reset(webView)
            }
            redirect.liftQuarantine()
            #expect(written == [false, false], "a page's write in the agent's gesture reached the system pasteboard: \(written)")
            #expect(lingered == [false], "a page's write reached the system pasteboard while the quarantine lingered")
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
                try await PageScripts.settle { standIn.changeCount != before }
                written = standIn.changeCount != before
            }
            #expect(result as? String == "false", "the agent world's execCommand(\"copy\") ran in a user gesture")
            #expect(!written, "script in the agent's world wrote the system pasteboard")
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
