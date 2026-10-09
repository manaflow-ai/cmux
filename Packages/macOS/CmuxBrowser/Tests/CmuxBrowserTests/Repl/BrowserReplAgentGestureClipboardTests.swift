import AppKit
import Testing
import WebKit

@testable import CmuxBrowser

extension BrowserReplPasteboardTests {
    /// An agent's click, key or page-world script gives the page a user
    /// gesture, and code holding one may run WebKit's own Copy
    /// (`execCommand("copy")`), which writes the system clipboard. Script the
    /// driver runs in its own worlds gets no gesture at all, and the agent's
    /// world has its `execCommand` clipboard commands switched off
    /// (``BrowserReplPageClipboard/agentWorldGuardSource``), so a listener the
    /// agent registered cannot copy with the gesture of the agent's click.
    ///
    /// The system pasteboard is a stand-in (both lookups WebKit makes,
    /// ``PageScripts/withStandInSystemPasteboard(_:)``), so a leaking build
    /// fills the stand-in and the person's clipboard stays untouched.
    @MainActor
    @Suite("Agent gestures", .serialized)
    struct AgentGestures {
        typealias PageScripts = BrowserReplPasteboardTests.PageScripts

        private static func reset(_ webView: WKWebView) async throws {
            _ = try await webView.callAsyncJavaScript("delete window.__done; return true", arguments: [:], in: nil, contentWorld: .page)
        }

        @Test("Script the agent runs in its own world gets no user gesture, so it cannot copy")
        func agentWorldScriptCannotCopy() async throws {
            var result: Any?
            var written = false
            try await PageScripts.withStandInSystemPasteboard { standIn in
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
            try await PageScripts.withStandInSystemPasteboard { standIn in
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

        /// Code in the agent's world (a listener it registered) keeps its
        /// world's own `execCommand`, and an agent's click that sets it off
        /// gives it a user gesture. The agent world's guard runs first in that
        /// world and refuses the clipboard commands, in every tab.
        @Test("An agent-world listener cannot copy with the gesture of an agent's click")
        func agentWorldListenerCannotCopy() async throws {
            var copied: Any?
            var written = false
            try await PageScripts.withStandInSystemPasteboard { standIn in
                let page = try await PageScripts.load(PageScripts.page) { _ in }
                let world = WKContentWorld.world(name: "cmux-agent-gesture-tests-listener")
                _ = try await page.browserReplCallAsyncJavaScript(
                    BrowserReplPageClipboard.agentWorldGuardSource + """
                    const field = document.getElementById('field');
                    field.addEventListener('click', () => {
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
                // The agent's click, as the driver runs it: a user gesture.
                try await PageScripts.click("field", in: page)
                copied = try await page.browserReplCallAsyncJavaScript("return globalThis.__copied ?? null", arguments: [:], in: nil, contentWorld: world, userGesture: false)
                _ = try await page.evaluateJavaScript("0")
                written = standIn.changeCount != before || standIn.string(forType: .string) != PageScripts.personsClipboard
            }
            #expect(copied as? Bool == false, "the agent world's execCommand(\"copy\") ran")
            #expect(!written, "an agent-world listener wrote the system pasteboard with the gesture of the agent's click")
        }
    }
}
