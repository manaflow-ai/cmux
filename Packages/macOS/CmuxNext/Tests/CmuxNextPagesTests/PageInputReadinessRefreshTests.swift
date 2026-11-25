import AppKit
@testable import CmuxNextPages
import CmuxNextTestSupport
import Testing
import WebKit

/// hq#15723: a LaunchServices launch with every core busy (the typing bench's L4) lost all 600 keys typed into the
/// agent chat. Each went to the key router's type-ahead (handled by the app) and waited for the page to say it was
/// ready, and that message never came: the page posts its `true` once, and a post lost on its way (Chromium's
/// Runtime gap after a commit) was never sent again. Now keys that wait make the host read the page's readiness
/// state as an evaluation's value (``PageInputReadiness/refresh()``), which needs no message.
@MainActor
@Suite(.closesItsWindows)
struct PageInputReadinessRefreshTests {
    final class Page: NSObject, WKNavigationDelegate {
        let readiness: PageInputReadiness
        let webView: WKWebView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        private var loaded: (() -> Void)?

        override init() {
            let configuration = WKWebViewConfiguration()
            readiness = PageInputReadiness(configuration: configuration)
            webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), configuration: configuration)
            super.init()
            readiness.attach(webView)
            window.contentView = webView
            webView.navigationDelegate = self
        }

        func load() async {
            _ = await PageTestWait.value("load") { (done: @escaping (Bool) -> Void) in
                loaded = { done(true) }
                webView.loadHTMLString("<!doctype html><body><textarea id=composer></textarea></body>", baseURL: nil)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded?()
            loaded = nil
        }
    }

    /// The composer has focus but its `true` never reached the host (here: the host's state is put back to not
    /// ready after it came). A key that waits reads the page's state, and the page turns ready for it.
    @Test func aWaitingKeyReadsTheReadinessALostMessageCarried() async throws {
        let page = Page()
        defer { page.window.closeAfterTest() }
        await page.load()
        _ = try await page.webView.callAsyncJavaScript("document.getElementById('composer').focus()", arguments: [:], in: nil, contentWorld: .page)
        #expect(await eventually { page.readiness.isReady })
        page.readiness.report(false) // the lost message: the host has not heard the page is ready
        #expect(!page.readiness.isReady)
        var ran = false
        page.readiness.whenReady { ran = true }
        #expect(await eventually { page.readiness.isReady && ran })
    }

    /// A state read that began before a new document reported not ready is not applied: it was the last document's.
    @Test func aReadFromTheLastDocumentIsDropped() async throws {
        let readiness = PageInputReadiness(configuration: WKWebViewConfiguration())
        var answer: CheckedContinuation<String?, Never>?
        readiness.stateReader = { await withCheckedContinuation { answer = $0 } }
        readiness.whenReady {}
        #expect(await eventually { answer != nil })
        readiness.report(false) // a new document
        answer?.resume(returning: #"{"ready":true,"epoch":1}"#)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!readiness.isReady)
    }

    /// A page that is not ready yet is read again until it is.
    @Test func aPageNotReadyYetIsReadAgain() async throws {
        let readiness = PageInputReadiness(configuration: WKWebViewConfiguration())
        readiness.refreshInterval = .milliseconds(5)
        var reads = 0
        readiness.stateReader = {
            reads += 1
            return reads < 3 ? #"{"ready":false}"# : #"{"ready":true,"epoch":4}"#
        }
        readiness.whenReady {}
        #expect(await eventually { readiness.isReady })
        #expect(reads == 3)
        #expect(readiness.focusEpoch == 4)
    }

    /// The composer mounts again right after the page reported ready (a new chat attaching at launch): the text typed
    /// before was refused at the old element's epoch and dropped, the first 1 to 9 of 600 keys per launch (hq#15723).
    /// Now the page is read again and the text goes to the new composer.
    @Test func textRefusedWhenTheComposerMountsAgainGoesToTheNewOne() async throws {
        let page = Page()
        defer { page.window.closeAfterTest() }
        await page.load()
        _ = try await page.webView.callAsyncJavaScript("document.getElementById('composer').focus()", arguments: [:], in: nil, contentWorld: .page)
        #expect(await eventually { page.readiness.isReady })
        let queuedAt = page.readiness.focusEpoch
        _ = try await page.webView.callAsyncJavaScript("""
            const old = document.getElementById('composer'); const next = document.createElement('textarea');
            old.replaceWith(next); next.id = 'composer'; next.focus();
            """, arguments: [:], in: nil, contentWorld: .page)
        #expect(await page.readiness.insert("hi", expectedEpoch: queuedAt) == false)
        let moved = await page.readiness.epochAfterRefusedInsert(at: queuedAt)
        #expect(moved != nil && moved != queuedAt)
        #expect(await page.readiness.insert("hi", expectedEpoch: moved))
        let value = try await page.webView.callAsyncJavaScript("return document.getElementById('composer').value", arguments: [:], in: nil, contentWorld: .page)
        #expect(value as? String == "hi")
    }

    /// A refused insert whose page now has no editable element focused stays dropped.
    @Test func textRefusedWithNoEditableFocusedStaysDropped() async throws {
        let page = Page()
        defer { page.window.closeAfterTest() }
        await page.load()
        _ = try await page.webView.callAsyncJavaScript("document.getElementById('composer').focus()", arguments: [:], in: nil, contentWorld: .page)
        #expect(await eventually { page.readiness.isReady })
        let queuedAt = page.readiness.focusEpoch
        _ = try await page.webView.callAsyncJavaScript("""
            const b = document.createElement('button'); document.body.appendChild(b); b.focus();
            """, arguments: [:], in: nil, contentWorld: .page)
        #expect(await page.readiness.epochAfterRefusedInsert(at: queuedAt) == nil)
    }

    /// Whether `condition` holds within 5 s, looked at every 10 ms.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
