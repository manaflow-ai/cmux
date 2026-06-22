import Foundation
import Testing
@testable import CmuxBrowser

/// Locks the byte-shape of the worker-lane JS-eval core builders lifted from
/// `TerminalController`'s `v2WaitForBrowserCondition` (condition-wait harness) and
/// `v2RunBrowserJavaScript` (frame-scoped async-eval wrapper plus the
/// pre-macOS-11 fallback) into ``BrowserControlService``. Each expectation is the
/// full literal the legacy inline body produced (with the interpolated condition /
/// script / frame selector / timeout / envelope keys), so a drift in any character
/// of the worker-lane wire script fails the test.
@Suite("BrowserControlService eval scripts")
struct BrowserControlServiceEvalScriptsTests {
    let service = BrowserControlService()

    @Test("condition-wait harness interpolates condition and timeout")
    func conditionWait() {
        #expect(service.conditionWaitScript(conditionScript: "window.ready", timeoutMs: 2500) == """
        (() => {
          const __cmuxEvaluate = () => {
            try {
              return !!(window.ready);
            } catch (_) {
              return false;
            }
          };

          if (__cmuxEvaluate()) {
            return true;
          }

          return new Promise((resolve) => {
            let finished = false;
            let observer = null;
            const cleanups = [];
            const finish = (value) => {
              if (finished) return;
              finished = true;
              if (observer) observer.disconnect();
              for (const cleanup of cleanups) {
                try { cleanup(); } catch (_) {}
              }
              resolve(value);
            };
            const recheck = () => {
              if (__cmuxEvaluate()) {
                finish(true);
              }
            };
            const addListener = (target, eventName, options) => {
              if (!target || typeof target.addEventListener !== 'function') return;
              const handler = () => recheck();
              target.addEventListener(eventName, handler, options);
              cleanups.push(() => target.removeEventListener(eventName, handler, options));
            };

            try {
              observer = new MutationObserver(() => recheck());
              observer.observe(document.documentElement || document, {
                childList: true,
                subtree: true,
                attributes: true,
                characterData: true
              });
            } catch (_) {}

            addListener(document, 'readystatechange', true);
            addListener(window, 'load', true);
            addListener(window, 'pageshow', true);
            addListener(window, 'hashchange', true);
            addListener(window, 'popstate', true);

            const timeoutId = window.setTimeout(() => {
              finish(false);
            }, 2500);
            cleanups.push(() => window.clearTimeout(timeoutId));
            recheck();
          });
        })()
        """)
    }

    @Test("eval body without a frame selector and without eval-wrapping")
    func evalBodyPlain() {
        #expect(service.evalFunctionBody(script: "document.title", frameSelector: nil, useEval: false) == """
        const __cmuxDoc = document;

        const __cmuxMaybeAwait = async (__r) => {
          if (__r !== null && (typeof __r === 'object' || typeof __r === 'function') && typeof __r.then === 'function') {
            return await __r;
          }
          return __r;
        };

        const __cmuxEvalInFrame = async function() {
          const document = __cmuxDoc;
          const __r = document.title;
          const __value = await __cmuxMaybeAwait(__r);
          return {
            __cmux_t: (typeof __value === 'undefined') ? 'undefined' : 'value',
            __cmux_v: __value
          };
        };

        return await __cmuxEvalInFrame();
        """)
    }

    @Test("eval body with a frame selector and eval-wrapping")
    func evalBodyFrameAndEval() {
        #expect(service.evalFunctionBody(script: "1 + 1", frameSelector: "iframe#x", useEval: true) == """
        let __cmuxDoc = document;
        try {
          const __cmuxFrame = document.querySelector("iframe#x");
          if (__cmuxFrame && __cmuxFrame.contentDocument) {
            __cmuxDoc = __cmuxFrame.contentDocument;
          }
        } catch (_) {}

        const __cmuxMaybeAwait = async (__r) => {
          if (__r !== null && (typeof __r === 'object' || typeof __r === 'function') && typeof __r.then === 'function') {
            return await __r;
          }
          return __r;
        };

        const __cmuxEvalInFrame = async function() {
          const document = __cmuxDoc;
          const __r = eval("1 + 1");
          const __value = await __cmuxMaybeAwait(__r);
          return {
            __cmux_t: (typeof __value === 'undefined') ? 'undefined' : 'value',
            __cmux_v: __value
          };
        };

        return await __cmuxEvalInFrame();
        """)
    }

    @Test("pre-macOS-11 fallback wraps the body in a self-invoking async IIFE")
    func evaluateFallback() {
        let body = service.evalFunctionBody(script: "document.title", frameSelector: nil, useEval: false)
        #expect(service.evaluateFallbackScript(asyncFunctionBody: body) == """
        (async () => {
          \(body)
        })()
        """)
    }
}
