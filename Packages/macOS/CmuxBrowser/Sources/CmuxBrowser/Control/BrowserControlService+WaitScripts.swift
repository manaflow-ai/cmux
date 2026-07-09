import Foundation

/// JavaScript condition-expression builders for `browser.wait`.
///
/// These are the pure, app-agnostic string-composition pieces of the former
/// `TerminalController.v2BrowserWait` body: each builds one boolean condition
/// expression (the `url_contains` / `text_contains` substring tests, the
/// `load_state` readiness checks, the user `function` wrapper, the default
/// `readyState === 'complete'` check, and the resolved-selector presence test)
/// that the caller hands to ``conditionWaitScript(conditionScript:timeoutMs:)``.
/// They take only their already-decoded raw inputs (and escape them via
/// ``jsonLiteral(_:)`` exactly as the legacy `v2JSONLiteral` interpolation did),
/// so they carry no `WebKit`, main-actor, or per-surface state.
///
/// The param-precedence resolution (`url_contains` over `text_contains` over
/// `load_state` over `function`, and a resolved selector overriding all of them),
/// the panel resolution, the WebKit evaluation, and the wire-payload shaping stay
/// in the app target on the nonisolated socket-worker lane, exactly where they ran
/// before: only the byte-identical condition-expression assembly moved here.
extension BrowserControlService {
    /// `url_contains` condition: true when `location.href` contains the substring.
    /// Byte-identical to the legacy interpolation.
    /// - Parameter substring: the raw substring to test for.
    /// - Returns: a JavaScript boolean expression.
    public func waitURLContainsScript(substring: String) -> String {
        let literal = jsonLiteral(substring)
        return "String(location.href || '').includes(\(literal))"
    }

    /// `text_contains` condition: true when `document.body.innerText` contains the
    /// substring. Byte-identical to the legacy interpolation.
    /// - Parameter substring: the raw substring to test for.
    /// - Returns: a JavaScript boolean expression.
    public func waitTextContainsScript(substring: String) -> String {
        let literal = jsonLiteral(substring)
        return "(document.body && String(document.body.innerText || '').includes(\(literal)))"
    }

    /// `load_state === 'interactive'` condition: true once `document.readyState` is
    /// `interactive` or `complete`. Byte-identical to the legacy multi-line
    /// expression.
    /// - Returns: a self-invoking JavaScript boolean expression.
    public func waitLoadStateInteractiveScript() -> String {
        return """
        (() => {
          const __state = String(document.readyState || '').toLowerCase();
          return __state === 'interactive' || __state === 'complete';
        })()
        """
    }

    /// `load_state` condition for any non-`interactive` state: true when
    /// `document.readyState` (lowercased) equals the requested state. Byte-identical
    /// to the legacy interpolation; the caller lowercases the state first, matching
    /// the legacy `normalizedLoadState`.
    /// - Parameter normalizedLoadState: the already-lowercased target ready state.
    /// - Returns: a JavaScript boolean expression.
    public func waitLoadStateScript(normalizedLoadState: String) -> String {
        let literal = jsonLiteral(normalizedLoadState)
        return "String(document.readyState || '').toLowerCase() === \(literal)"
    }

    /// `function` condition: wraps the caller-supplied expression in a truthy IIFE.
    /// Byte-identical to the legacy interpolation; `function` is spliced raw
    /// (not escaped), exactly as before.
    /// - Parameter function: the raw user JavaScript expression.
    /// - Returns: a self-invoking JavaScript boolean expression.
    public func waitFunctionScript(function: String) -> String {
        return "(() => { return !!(\(function)); })()"
    }

    /// The default condition when no other matcher was provided: true once the page
    /// has finished loading. Byte-identical to the legacy literal.
    /// - Returns: a JavaScript boolean expression.
    public func waitDefaultReadyScript() -> String {
        return "document.readyState === 'complete'"
    }

    /// The resolved-selector condition: true once the selector matches an element.
    /// Byte-identical to the legacy interpolation; the caller passes the already
    /// ref-resolved selector, exactly as before.
    /// - Parameter selector: the resolved CSS selector / element-ref target.
    /// - Returns: a JavaScript boolean expression.
    public func waitSelectorPresentScript(selector: String) -> String {
        let literal = jsonLiteral(selector)
        return "document.querySelector(\(literal)) !== null"
    }
}
