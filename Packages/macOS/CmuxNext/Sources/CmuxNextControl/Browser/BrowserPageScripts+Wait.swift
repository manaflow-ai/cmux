import Foundation

/// Page scripts for `browser.page.wait` and element screenshots.
extension BrowserPageScripts {
    /// One wait condition, as the old `cmux browser wait` chose it: a
    /// selector wins, then `url_contains`, `text_contains`, `load_state`,
    /// `function`; with none, the document has finished loading.
    enum WaitCondition: Sendable, Equatable {
        case selector(String)
        case urlContains(String)
        case textContains(String)
        /// `interactive` also accepts `complete`.
        case loadState(String)
        /// A JavaScript expression; the wait ends when it is truthy.
        case function(String)

        /// The JavaScript expression that is truthy once the condition holds.
        var expression: String {
            switch self {
            case .selector(let selector):
                "(() => { const raw = \(literal(selector)); const ref = raw.replace(/^@/, ''); "
                    + "return /^e\\d+$/.test(ref) ? document.querySelector('[data-cmux-ref=\"' + ref + '\"]') : document.querySelector(raw); })()"
            case .urlContains(let text):
                "String(location.href || '').includes(\(literal(text)))"
            case .textContains(let text):
                "(document.body ? document.body.innerText : '').includes(\(literal(text)))"
            case .loadState(let state) where state == "interactive":
                "(document.readyState === 'interactive' || document.readyState === 'complete')"
            case .loadState(let state):
                "document.readyState === \(literal(state))"
            case .function(let expression):
                "(() => { return (\n\(expression)\n); })()"
            }
        }

        /// Script state and `history.pushState` change without a DOM
        /// mutation or event, so these also recheck on a page timer.
        var rechecksOnTimer: Bool {
            switch self {
            case .function, .urlContains: true
            default: false
            }
        }
    }

    /// The body of an async function that resolves to `{met, error}`: `met`
    /// once `condition` holds, or false after `timeoutMs`. It rechecks on
    /// DOM mutations and load/navigation events, and for script state and
    /// URLs on a 100 ms page timer (in the page; the app never wakes). An
    /// exception in the condition counts as not met (`error` keeps the last).
    static func waitScript(_ condition: WaitCondition, timeoutMs: Int) -> String {
        """
        let lastError = null;
        const check = () => { try { return !!(\(condition.expression)); } catch (e) { lastError = String(e); return false; } };
        if (check()) { return { met: true, error: null }; }
        return await new Promise((resolve) => {
          const events = ['load', 'pageshow', 'hashchange', 'popstate'];
          let done = false;
          let observer = null;
          let timer = null;
          let recheck = null;
          const finish = (met) => {
            if (done) { return; }
            done = true;
            if (observer) { observer.disconnect(); }
            for (const name of events) { window.removeEventListener(name, onEvent, true); }
            document.removeEventListener('readystatechange', onEvent, true);
            clearTimeout(timer);
            clearInterval(recheck);
            resolve({ met, error: lastError });
          };
          const onEvent = () => { if (check()) { finish(true); } };
          observer = new MutationObserver(onEvent);
          observer.observe(document, { childList: true, subtree: true, attributes: true, characterData: true });
          for (const name of events) { window.addEventListener(name, onEvent, true); }
          document.addEventListener('readystatechange', onEvent, true);
          timer = setTimeout(() => finish(check()), \(max(0, timeoutMs)));
          \(condition.rechecksOnTimer ? "recheck = setInterval(onEvent, 100);" : "")
        });
        """
    }

    /// Scrolls the element into view unless it is fully visible, then
    /// returns its visible viewport rectangle and the viewport size (CSS px).
    static func elementClip(_ selector: String) -> String {
        wrap(find(selector) + """
        const vw = window.innerWidth, vh = window.innerHeight;
        if (!(vw > 0 && vh > 0)) { return { error: 'The page has no viewport' }; }
        const before = el.getBoundingClientRect();
        if (before.top < 0 || before.left < 0 || before.bottom > vh || before.right > vw) {
          el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
        }
        const r = el.getBoundingClientRect();
        const x = Math.max(0, r.left), y = Math.max(0, r.top);
        const width = Math.min(vw, r.right) - x, height = Math.min(vh, r.bottom) - y;
        if (!(width > 0 && height > 0)) { return { error: 'Element has no visible area: ' + raw }; }
        return { value: { x, y, width, height, viewport_width: vw, viewport_height: vh } };
        """)
    }
}
