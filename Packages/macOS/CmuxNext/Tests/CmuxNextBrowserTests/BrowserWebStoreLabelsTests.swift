import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing
import WebKit

/// Lawrence 2026-11-16: the Chrome Web Store's install button read "Add to Chrome" in cmux. The
/// store's buttons now say cmux (``BrowserWebStoreLabels``), from the server-rendered page on,
/// through the store's re-renders, and never anywhere else. Runs the script in a real WebKit
/// page at document start, as Chromium runs it (`CEFDocumentScripts`).
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct BrowserWebStoreLabelsTests {
    static let store = URL(string: "https://chromewebstore.google.com/detail/stayfocusd/laankejkbhbdhmipfmgcngdelahlfoji")!

    /// A store item page as the server renders it: the install button, a description that names
    /// Chrome, the store's own name in a button, and a German button.
    static let page = """
    <html><body>
    <section><h1>StayFocusd</h1>
      <button id="add" aria-label="Add to Chrome"><span class="ripple"></span><span>Add to Chrome</span></button>
      <button id="store">Chrome Web Store</button>
      <button id="install">Install Chrome</button>
      <button id="de"><span>Zu Chrome hinzufügen</span></button>
      <button id="ja"><span>Chrome に追加</span></button>
      <p id="description">A productivity extension for Google Chrome.</p>
      <a id="link" href="#">Add to Chrome</a>
    </section>
    </body></html>
    """

    private func load(_ html: String, at url: URL) async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(WKUserScript(
            source: BrowserWebStoreLabels.source, injectionTime: .atDocumentStart, forMainFrameOnly: true,
            in: WKContentWorld.world(name: BrowserWebStoreLabels.world)))
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: configuration)
        view.loadHTMLString(html, baseURL: url)
        try await until("the page loaded") {
            // The first document is the empty one the view starts with: wait for this page's own button.
            let ready = try? await view.evaluateJavaScript("document.readyState === 'complete' && document.getElementById('add') !== null") as? Bool
            return ready == true
        }
        return view
    }

    private func text(_ view: WKWebView, _ expression: String) async throws -> String {
        try await view.evaluateJavaScript(expression) as? String ?? "<none>"
    }

    private func until(_ what: String, _ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out: \(what)")
    }

    @Test func theServerRenderedInstallButtonSaysCmux() async throws {
        let view = try await load(Self.page, at: Self.store)
        #expect(try await text(view, "document.getElementById('add').textContent") == "Add to cmux")
        #expect(try await text(view, "document.getElementById('add').getAttribute('aria-label')") == "Add to cmux")
        #expect(try await text(view, "document.getElementById('de').textContent") == "Zu cmux hinzufügen")
        #expect(try await text(view, "document.getElementById('ja').textContent") == "cmux に追加")
    }

    @Test func onlyButtonsAndOnlyTheBrowsersNameChange() async throws {
        let view = try await load(Self.page, at: Self.store)
        #expect(try await text(view, "document.getElementById('store').textContent") == "Chrome Web Store")
        #expect(try await text(view, "document.getElementById('install').textContent") == "Install Chrome")
        #expect(try await text(view, "document.getElementById('description').textContent") == "A productivity extension for Google Chrome.")
        #expect(try await text(view, "document.getElementById('link').textContent") == "Add to Chrome")
    }

    /// The store re-renders the button after install ("Remove from Chrome"), replaces it on SPA
    /// navigation, and changes its text in place. Each is renamed before the task that made it
    /// ends: a check in the same task never sees the old label.
    @Test func theStoresReRendersSayCmuxBeforeTheyPaint() async throws {
        let view = try await load(Self.page, at: Self.store)
        let seen = try await view.callAsyncJavaScript("""
            return await (() => {
              const add = document.getElementById('add');
              add.querySelector('span:last-child').firstChild.nodeValue = 'Remove from Chrome';
              add.setAttribute('aria-label', 'Remove from Chrome');
              const next = document.createElement('div');
              next.innerHTML = '<button id="next"><span>Add to Chrome</span></button>';
              document.body.appendChild(next);
              const late = document.createElement('button');
              document.body.appendChild(late);
              late.textContent = 'Add to Chrome';
              return new Promise((resolve) => queueMicrotask(() => resolve([
                add.textContent, add.getAttribute('aria-label'),
                document.getElementById('next').textContent, late.textContent,
              ].join('|'))));
            })();
            """, contentWorld: .page) as? String
        #expect(seen == "Remove from cmux|Remove from cmux|Add to cmux|Add to cmux")
    }

    @Test func otherSitesKeepTheirWords() async throws {
        for url in [URL(string: "https://example.com/")!, URL(string: "https://chromewebstore.google.com.evil.test/")!,
                    URL(string: "http://chromewebstore.google.com/")!] {
            let view = try await load(Self.page, at: url)
            #expect(try await text(view, "document.getElementById('add').textContent") == "Add to Chrome", "\(url)")
        }
    }

    /// Chromium installs it with the other document-start scripts, once for every browser.
    @Test func chromiumInstallsItInItsOwnWorld() {
        let scripts = CEFDocumentScripts(post: .pageChannel).all
        #expect(scripts.contains { $0.source == BrowserWebStoreLabels.source && $0.world == BrowserWebStoreLabels.world && !$0.allFrames })
    }
}
