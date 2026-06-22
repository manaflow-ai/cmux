import Foundation

/// JavaScript builders for the worker-lane browser JS-eval core.
///
/// These are the pure, app-agnostic string-composition pieces of the
/// `TerminalController` browser eval plumbing: the condition-wait harness
/// (`v2WaitForBrowserCondition`) and the frame-scoped async-eval wrapper
/// (`v2RunBrowserJavaScript`). They take only their script/selector/flag inputs
/// and the service's ``BrowserEvalEnvelope`` constants, so they carry no
/// `WebKit`, main-actor, or per-surface state.
///
/// The WebKit evaluation itself (the `WKWebView.evaluateJavaScript` /
/// `callAsyncJavaScript` seam, the page→isolated-world CSP retry, the panel
/// resolution, the element-ref/frame-selector lookups, and the envelope
/// unwrapping that re-materializes the `undefined` sentinel) stays in the app
/// target on the nonisolated socket-worker lane, exactly where it ran before:
/// only the byte-identical script assembly moved here.
extension BrowserControlService {
    /// The bounded condition-wait harness for `browser.wait_for` and the internal
    /// readiness waits.
    ///
    /// Evaluates `conditionScript` once; if falsy, installs a `MutationObserver`
    /// plus `readystatechange`/`load`/`pageshow`/`hashchange`/`popstate`
    /// listeners and re-checks on every signal, resolving `true` on the first
    /// truthy evaluation or `false` after `timeoutMs`. Byte-identical to the
    /// script the former `v2WaitForBrowserCondition` assembled inline; the caller
    /// runs it through ``v2RunBrowserJavaScript`` with `useEval: false`.
    ///
    /// - Parameters:
    ///   - conditionScript: the JavaScript condition expression to poll.
    ///   - timeoutMs: the wait budget in milliseconds.
    /// - Returns: a self-invoking JavaScript expression resolving to a boolean.
    public func conditionWaitScript(conditionScript: String, timeoutMs: Int) -> String {
        return """
        (() => {
          const __cmuxEvaluate = () => {
            try {
              return !!(\(conditionScript));
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
            }, \(timeoutMs));
            cleanups.push(() => window.clearTimeout(timeoutId));
            recheck();
          });
        })()
        """
    }

    /// The frame-scoped async-eval function body for the worker-lane JS-eval core.
    ///
    /// Composes the optional frame prelude (which retargets `document` to a
    /// same-document iframe's `contentDocument` when `frameSelector` is set), the
    /// execution block (an `eval(...)` of the script when `useEval`, otherwise the
    /// raw script as an expression), and the `__cmuxEvalInFrame` wrapper that
    /// awaits a thenable result and tags it with the
    /// ``BrowserEvalEnvelope/typeUndefined``/``BrowserEvalEnvelope/typeValue``
    /// envelope so the caller can distinguish JavaScript `undefined` from `null`.
    /// Byte-identical to the `asyncFunctionBody` the former
    /// `v2RunBrowserJavaScript` assembled inline; the caller evaluates it with
    /// `preferAsync` (macOS 11+) or via ``evaluateFallbackScript(asyncFunctionBody:)``.
    ///
    /// - Parameters:
    ///   - script: the user/automation JavaScript to run.
    ///   - frameSelector: the optional iframe selector to scope `document` to.
    ///   - useEval: whether to wrap `script` in `eval(...)` (a user `browser.eval`)
    ///     or splice it as a raw expression (internal automation).
    /// - Returns: the async function body to evaluate.
    public func evalFunctionBody(script: String, frameSelector: String?, useEval: Bool) -> String {
        let framePrelude: String
        if let frameSelector {
            let selectorLiteral = jsonLiteral(frameSelector)
            framePrelude = """
            let __cmuxDoc = document;
            try {
              const __cmuxFrame = document.querySelector(\(selectorLiteral));
              if (__cmuxFrame && __cmuxFrame.contentDocument) {
                __cmuxDoc = __cmuxFrame.contentDocument;
              }
            } catch (_) {}
            """
        } else {
            framePrelude = "const __cmuxDoc = document;"
        }

        let executionBlock: String
        if useEval {
            let scriptLiteral = jsonLiteral(script)
            executionBlock = "const __r = eval(\(scriptLiteral));"
        } else {
            executionBlock = "const __r = \(script);"
        }

        return """
        \(framePrelude)

        const __cmuxMaybeAwait = async (__r) => {
          if (__r !== null && (typeof __r === 'object' || typeof __r === 'function') && typeof __r.then === 'function') {
            return await __r;
          }
          return __r;
        };

        const __cmuxEvalInFrame = async function() {
          const document = __cmuxDoc;
          \(executionBlock)
          const __value = await __cmuxMaybeAwait(__r);
          return {
            \(evalEnvelope.typeKey): (typeof __value === 'undefined') ? '\(evalEnvelope.typeUndefined)' : '\(evalEnvelope.typeValue)',
            \(evalEnvelope.valueKey): __value
          };
        };

        return await __cmuxEvalInFrame();
        """
    }

    /// Wraps ``evalFunctionBody(script:frameSelector:useEval:)`` in a self-invoking
    /// async IIFE for the pre-macOS-11 `evaluateJavaScript` path (which cannot use
    /// `callAsyncJavaScript`). Byte-identical to the `evaluateFallback` wrapper the
    /// former `v2RunBrowserJavaScript` assembled inline.
    ///
    /// - Parameter asyncFunctionBody: the body from
    ///   ``evalFunctionBody(script:frameSelector:useEval:)``.
    /// - Returns: a self-invoking async JavaScript expression.
    public func evaluateFallbackScript(asyncFunctionBody: String) -> String {
        return """
        (async () => {
          \(asyncFunctionBody)
        })()
        """
    }
}
