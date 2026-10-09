import Foundation
import Testing
import WebKit

@testable import CmuxBrowser

/// `frame.contentFrame(s)` and `frame.ownerBox` tie an `<iframe>` element
/// to its child frame's id. The parent's script sees the element's
/// position in `window.frames`, WebKit's tree names child frames by id;
/// a frame in a shadow tree is in the tree but not in `window.frames`, and
/// the page can add or remove frames between the two reads. Neither may
/// bind the element to a sibling's frame.
@MainActor
@Suite(.serialized)
struct BrowserReplFrameBindingTests {
    private let binding = BrowserReplFrameBinding(world: WKContentWorld.world(name: "cmux-binding-test"))

    /// Positions in `window.frames` of the iframes with `ids`, and its length.
    private static func positions(of ids: [String], in webView: WKWebView, then after: String = "") async throws -> (value: [Int], length: Int) {
        let value = try await webView.callAsyncJavaScript(
            """
            const index = new Map();
            for (let i = 0; i < window.frames.length; i++) index.set(window.frames[i], i);
            const out = ids.map((id) => {
              const el = document.getElementById(id) || (document.getElementById("host") && document.getElementById("host").shadowRoot.getElementById(id));
              const w = el && el.contentWindow;
              return w && index.has(w) ? index.get(w) : -1;
            });
            const length = window.frames.length;
            \(after)
            return [out, length];
            """,
            arguments: ["ids": ids],
            in: nil,
            contentWorld: .page
        ) as? [Any]
        let list = (value?.first as? [NSNumber])?.map(\.intValue) ?? []
        let length = (value?.last as? NSNumber)?.intValue ?? -1
        return (list, length)
    }

    private func bound(_ page: FramePage, ids: [String], after: String = "") async throws -> [String?]? {
        let webView = page.webView
        guard let result = try await binding.bind(
            parentID: nil,
            in: webView,
            readTree: { await BrowserReplFrame.readTree(of: webView) },
            body: { _ in try await Self.positions(of: ids, in: webView, then: after) }
        ) else { return nil }
        let tree = await BrowserReplFrame.readTree(of: webView)
        return result.value.map { position in
            guard let id = result.children[position] else { return nil }
            return tree.first { $0.frameID == id }.flatMap { URL(string: $0.url)?.host }
        }
    }

    @Test("A frame in a shadow tree, created first, does not shift the light frames onto it")
    func shadowFrameDoesNotShiftTheLightFrames() async throws {
        let page = try await FramePage.load(
            html: """
            <div id=host></div>
            <script>
              document.getElementById("host").attachShadow({ mode: "open" }).innerHTML = '<iframe id=s src="cmux-test://shadow.test/child"></iframe>';
            </script>
            <iframe id=a src="cmux-test://a.test/child"></iframe>
            <iframe id=b src="cmux-test://b.test/child"></iframe>
            """,
            loaded: { frames in frames.count >= 4 && frames.allSatisfy { !$0.url.isEmpty } }
        )
        let hosts = try await bound(page, ids: ["a", "b", "s"])
        #expect(hosts == ["a.test", "b.test", nil], "\(String(describing: hosts))")
    }

    @Test("A frame removed between the parent's read and the tree's never binds an element to its sibling")
    func removalBetweenReadsDoesNotShift() async throws {
        let page = try await FramePage.load(
            html: """
            <iframe id=z src="cmux-test://z.test/child"></iframe>
            <iframe id=a src="cmux-test://a.test/child"></iframe>
            <iframe id=b src="cmux-test://b.test/child"></iframe>
            """,
            loaded: { frames in frames.count >= 4 && frames.allSatisfy { !$0.url.isEmpty } }
        )
        // The first read sees z before a; z is gone before the tree is read.
        let hosts = try await bound(page, ids: ["a"], after: #"const z = document.getElementById("z"); if (z) z.remove();"#)
        // The second try reads a settled page and binds a to its own frame.
        #expect(hosts == ["a.test"], "\(String(describing: hosts))")
    }

    @Test("A page that keeps changing its frames gets no binding, never a sibling's")
    func churningFramesFailClosed() async throws {
        let page = try await FramePage.load(
            html: """
            <iframe id=z1 src="cmux-test://z1.test/child"></iframe>
            <iframe id=z2 src="cmux-test://z2.test/child"></iframe>
            <iframe id=z3 src="cmux-test://z3.test/child"></iframe>
            <iframe id=z4 src="cmux-test://z4.test/child"></iframe>
            <iframe id=z5 src="cmux-test://z5.test/child"></iframe>
            <iframe id=z6 src="cmux-test://z6.test/child"></iframe>
            <iframe id=a src="cmux-test://a.test/child"></iframe>
            <iframe id=b src="cmux-test://b.test/child"></iframe>
            """,
            loaded: { frames in frames.count >= 9 && frames.allSatisfy { !$0.url.isEmpty } }
        )
        // Every read of the parent removes the first remaining frame.
        let hosts = try await bound(page, ids: ["a"], after: #"const f = document.querySelector("iframe"); if (f && f.id !== "a") f.remove();"#)
        #expect(hosts == nil || hosts == ["a.test"], "\(String(describing: hosts))")
        #expect(hosts?.contains { $0 != nil && $0 != "a.test" } != true)
    }

    @Test("Each child frame's position is its place in window.frames, also cross-origin")
    func childPositionsMatchWindowFrames() async throws {
        let page = try await FramePage.load()
        let webView = page.webView
        let result = try await binding.bind(
            parentID: nil,
            in: webView,
            readTree: { await BrowserReplFrame.readTree(of: webView) },
            body: { positions in (positions, -1) }
        )
        // The body reported no length, so nothing binds.
        #expect(result == nil)
        let checked = try #require(try await binding.bind(
            parentID: nil,
            in: webView,
            readTree: { await BrowserReplFrame.readTree(of: webView) },
            body: { positions in
                let length = try await webView.callAsyncJavaScript("return window.frames.length", arguments: [:], in: nil, contentWorld: .page) as? Int ?? -1
                return (positions, length)
            }
        ))
        let allowed = try #require(page.frame(host: "allowed.test"))
        let blocked = try #require(page.frame(host: "blocked.test"))
        #expect(checked.value[allowed.frameID] == 0)
        #expect(checked.value[blocked.frameID] == 1)
        #expect(checked.children == [0: allowed.frameID, 1: blocked.frameID])
    }
}
