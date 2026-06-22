import Foundation
import Testing
@testable import CmuxBrowser

/// Locks the byte-shape of the `browser.wait` condition-expression builders lifted
/// from `TerminalController`'s `v2BrowserWait` body into ``BrowserControlService``.
/// Each expectation is the full literal the legacy inline branch produced (with the
/// interpolated, `jsonLiteral`-escaped substring / load-state / function / selector),
/// so a drift in any character of the worker-lane wire condition fails the test.
@Suite("BrowserControlService wait scripts")
struct BrowserControlServiceWaitScriptsTests {
    let service = BrowserControlService()

    @Test("url_contains escapes the substring and tests location.href")
    func urlContains() {
        // jsonLiteral routes through JSONSerialization, which escapes both the
        // quote and the forward slash (`\/`), exactly as the legacy v2JSONLiteral.
        #expect(
            service.waitURLContainsScript(substring: "/dash\"board")
                == "String(location.href || '').includes(\"\\/dash\\\"board\")"
        )
    }

    @Test("text_contains escapes the substring and tests body innerText")
    func textContains() {
        #expect(
            service.waitTextContainsScript(substring: "Hello")
                == "(document.body && String(document.body.innerText || '').includes(\"Hello\"))"
        )
    }

    @Test("load_state interactive checks readyState for interactive or complete")
    func loadStateInteractive() {
        #expect(service.waitLoadStateInteractiveScript() == """
        (() => {
          const __state = String(document.readyState || '').toLowerCase();
          return __state === 'interactive' || __state === 'complete';
        })()
        """)
    }

    @Test("load_state compares lowercased readyState to the escaped state")
    func loadState() {
        #expect(
            service.waitLoadStateScript(normalizedLoadState: "complete")
                == "String(document.readyState || '').toLowerCase() === \"complete\""
        )
    }

    @Test("function wraps the raw expression in a truthy IIFE without escaping")
    func function() {
        #expect(
            service.waitFunctionScript(function: "window.app && app.ready()")
                == "(() => { return !!(window.app && app.ready()); })()"
        )
    }

    @Test("default condition checks readyState complete")
    func defaultReady() {
        #expect(service.waitDefaultReadyScript() == "document.readyState === 'complete'")
    }

    @Test("selector-present escapes the selector and tests querySelector")
    func selectorPresent() {
        #expect(
            service.waitSelectorPresentScript(selector: "#main .row")
                == "document.querySelector(\"#main .row\") !== null"
        )
    }
}
