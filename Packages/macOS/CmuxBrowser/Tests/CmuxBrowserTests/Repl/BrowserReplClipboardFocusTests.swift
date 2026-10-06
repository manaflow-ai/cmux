import AppKit
import Testing
import WebKit

@testable import CmuxBrowser

/// Keys and clipboard shortcuts refuse a blocked frame that holds the focus
/// through its frame element.
@MainActor
@Suite("Clipboard command focus", .serialized)
struct BrowserReplClipboardFocusTests {
    private static let focusBlockedFrame = "document.getElementById('b').focus(); return document.activeElement.id"

    @Test("A blocked frame focused through its element is found when a shadow-tree frame comes first")
    func ownerFocusWithAShadowFrameFirst() async throws {
        let page = try await FramePage.load(
            html: """
            <div id=host></div>
            <script>
              document.getElementById("host").attachShadow({ mode: "open" }).innerHTML = '<iframe src="cmux-test://allowed.test/shadow"></iframe>';
            </script>
            <iframe id=a src="cmux-test://allowed.test/child"></iframe>
            <iframe id=b src="cmux-test://blocked.test/x"></iframe>
            """,
            loaded: { frames in frames.count >= 4 && frames.allSatisfy { !$0.url.isEmpty } }
        )
        let gate = BrowserReplFrameGateTests.gate()
        _ = try await page.run(Self.focusBlockedFrame, in: page.main)
        let error = await BrowserReplFrameGateTests.error { try await gate.checkFocus(in: page.webView, frames: page.frames) }
        #expect(error?.code == "blocked", "keys could reach the blocked frame its parent focused: \(String(describing: error))")
    }
}

/// A frame the domain policy blocks can still run in a tab a session
/// created (it loaded before the policy was tightened). Its page script
/// must not put data on the tab's clipboard, which `clipboard.read` hands to
/// the agent: the tab's clipboard takes a page's write only from a frame the
/// creating session's policy allows.
@MainActor
@Suite("Page clipboard writes by frame", .serialized)
struct BrowserReplPageClipboardFrameTests {
    @Test("A blocked frame's page-script write is refused; an allowed frame's lands")
    func blockedFrameWritesAreRefused() async throws {
        let shim = try BrowserReplPasteboardTests.PageScripts.shim()
        var policy = BrowserReplDomainPolicy()
        policy.prohibited = [try BrowserReplDomainPattern.parse("cmux-test://blocked.test", title: "t")]
        let blockedPolicy = policy
        var routed: [String] = []
        let page = try await FramePage.load(configure: { configuration in
            let probe = WKWebView(frame: .zero, configuration: configuration)
            BrowserReplPageClipboard(shim: shim).install(
                on: probe,
                refusing: { _, info in blockedPolicy.blockReason(document: BrowserReplFrameDocument(info: info)) },
                onWrite: { _, items in
                    for item in items {
                        if let data = (item["base64"] as? String).flatMap({ Data(base64Encoded: $0) }) {
                            routed.append(String(decoding: data, as: UTF8.self))
                        }
                    }
                    return true
                }
            )
        })
        let write = """
        try { await navigator.clipboard.writeText(text); return "ok"; } catch (e) { return "rejected " + e.name; }
        """
        let blocked = try #require(page.frame(host: "blocked.test"))
        let allowed = try #require(page.frame(path: "/child"))
        let fromBlocked = try await page.webView.callAsyncJavaScript(write, arguments: ["text": "from the blocked frame"], in: blocked.info, contentWorld: .page) as? String
        let fromAllowed = try await page.webView.callAsyncJavaScript(write, arguments: ["text": "from the allowed frame"], in: allowed.info, contentWorld: .page) as? String
        #expect(fromBlocked?.hasPrefix("rejected") == true, "the blocked frame's write was taken: \(String(describing: fromBlocked))")
        #expect(fromAllowed == "ok")
        #expect(routed == ["from the allowed frame"])
    }
}
