import AppKit
import Testing
import WebKit

@testable import CmuxBrowser

/// Meta+C, Meta+X and Meta+V in a tab a session created run on the tab's
/// virtual clipboard only: a script in the driver's world dispatches the
/// `copy`, `cut` or `paste` event in the focused frame's document and does
/// the default action there, in one script turn, after the gate authorized
/// that document. No pasteboard is involved, so nothing another web view
/// writes can become the tab's clipboard, and the paste reaches only the
/// document the gate checked.
///
/// Nested in the pasteboard suite: one test stands in for the system
/// pasteboard, a process-wide lookup.
extension BrowserReplPasteboardTests {
    @MainActor
    @Suite("Clipboard shortcuts", .serialized)
    struct ClipboardShortcuts {
        private static func text(_ items: [[String: Any]]?, _ type: String = "text/plain") -> String? {
            guard let item = items?.first(where: { $0["type"] as? String == type }),
                  let data = (item["base64"] as? String).flatMap({ Data(base64Encoded: $0) }) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }

        private static func item(_ text: String) -> [String: Any] {
            ["type": "text/plain", "base64": Data(text.utf8).base64EncodedString()]
        }

        @Test("Copy takes the focused field's selection, Paste inserts the tab's clipboard")
        func copyAndPasteRunOnTheTabClipboard() async throws {
            let page = try await FramePage.load()
            let gate = BrowserReplFrameGateTests.gate()
            let allowed = try #require(page.frame(path: "/child"))
            _ = try await page.run("document.getElementById('a').focus(); return true", in: page.main)
            _ = try await page.run("const f = document.getElementById('f'); f.value = 'copy me'; f.focus(); f.select(); return true", in: allowed)
            let webView = page.webView
            let copied = try await gate.runClipboardShortcut(.copy, clipboard: [], in: webView, frames: { await BrowserReplFrame.readTree(of: webView) })
            #expect(Self.text(copied) == "copy me")
            _ = try await page.run("const f = document.getElementById('f'); f.value = ''; f.focus(); return true", in: allowed)
            let pasted = try await gate.runClipboardShortcut(.paste, clipboard: [Self.item("pasted")], in: webView, frames: { await BrowserReplFrame.readTree(of: webView) })
            #expect(pasted == nil)
            #expect(try await page.run("return document.getElementById('f').value", in: allowed) as? String == "pasted")
        }

        /// r11: the focus can move into a blocked frame after the last check and
        /// before the paste. The paste goes only to the document the gate
        /// authorized, in the same script turn as its check, so the blocked
        /// frame never gets the tab's clipboard wherever the focus went.
        @Test("A paste never reaches a blocked frame the focus moved into after the check")
        func pasteNeverReachesABlockedFrameTheFocusMovedInto() async throws {
            let page = try await FramePage.load()
            let gate = BrowserReplFrameGateTests.gate()
            let allowed = try #require(page.frame(path: "/child"))
            let blocked = try #require(page.frame(host: "blocked.test"))
            _ = try await page.run("document.getElementById('a').focus(); return true", in: page.main)
            _ = try await page.run("document.getElementById('f').focus(); return true", in: allowed)
            let webView = page.webView
            _ = try? await gate.runClipboardShortcut(
                .paste,
                clipboard: [Self.item("the session's clipboard")],
                in: webView,
                frames: { await BrowserReplFrame.readTree(of: webView) },
                beforeDelivery: {
                    _ = try await page.run("document.getElementById('b').focus(); return true", in: page.main)
                    _ = try await page.run("document.getElementById('f').focus(); return true", in: blocked)
                }
            )
            let inBlocked = try await page.run("return document.getElementById('f').value", in: blocked) as? String
            #expect(inBlocked == "", "the paste reached the blocked frame")
        }

        @Test("Copy, Cut and Paste with the focus in a blocked frame are refused and touch nothing")
        func shortcutsWithTheFocusInABlockedFrameAreRefused() async throws {
            let page = try await FramePage.load()
            let gate = BrowserReplFrameGateTests.gate()
            let blocked = try #require(page.frame(host: "blocked.test"))
            _ = try await page.run("document.getElementById('b').focus(); return true", in: page.main)
            _ = try await page.run("const f = document.getElementById('f'); f.value = 'blocked text'; f.focus(); f.select(); return true", in: blocked)
            let webView = page.webView
            for shortcut in [BrowserReplFrameGate.ClipboardShortcut.copy, .cut, .paste] {
                let error = await BrowserReplFrameGateTests.error {
                    try await gate.runClipboardShortcut(shortcut, clipboard: [Self.item("x")], in: webView, frames: { await BrowserReplFrame.readTree(of: webView) })
                }
                #expect(error?.code == "blocked", "\(shortcut) ran with the focus in a blocked frame: \(String(describing: error))")
            }
            #expect(try await page.run("return document.getElementById('f').value", in: blocked) as? String == "blocked text")
        }

        /// r11: a Copy whose handler clears the selection without cancelling
        /// copies nothing; a copy another web view makes meanwhile never becomes
        /// the tab's clipboard.
        @Test("A copy in another web view during a Copy never becomes the tab's clipboard")
        func anotherWebViewsCopyNeverBecomesTheTabClipboard() async throws {
            try await BrowserReplPasteboardTests.PageScripts.withStandInSystemPasteboard { standIn in
                let tab = try await BrowserReplPasteboardTests.PageScripts.load(
                    """
                    <input id=i value="tab text"><script>
                    addEventListener('copy', () => {
                      const end = Date.now() + 500;
                      while (Date.now() < end) {}
                      document.getElementById('i').setSelectionRange(0, 0);
                    });
                    </script>
                    """
                ) { _ in }
                _ = try await tab.callAsyncJavaScript("const i = document.getElementById('i'); i.focus(); i.select(); return true", arguments: [:], in: nil, contentWorld: .page)
                let other = try await BrowserReplPasteboardTests.PageScripts.load("<input id=o value=\"another web view's text\">") { _ in }
                let gate = BrowserReplFrameGate(world: BrowserReplFrameGateTests.world)
                let copy = Task { @MainActor in
                    Self.text(try await gate.runClipboardShortcut(.copy, clipboard: [], in: tab, frames: { await BrowserReplFrame.readTree(of: tab) }))
                }
                _ = try await other.callAsyncJavaScript(
                    "const o = document.getElementById('o'); o.focus(); o.select(); return document.execCommand('copy')",
                    arguments: [:], in: nil, contentWorld: .page
                )
                let copied = try await copy.value
                #expect(copied != "another web view's text", "another web view's copy became the tab's clipboard")
                #expect(copied == "")
                _ = standIn
            }
        }
    }
}
