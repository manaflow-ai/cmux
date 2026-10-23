import Foundation

/// The page side of email verification AutoFill
/// (plans/cmux-next/email-verification-autofill/DESIGN.md "Page signal" and "Delivery"),
/// for both engines. The detector runs in its own isolated world (WebKit content world, CEF
/// isolated world) in the top frame only, so a page cannot call the channel, fake a report, or
/// replace the DOM functions the scripts use. It reports only `true` ("this page waits for a
/// verification email"), never page text. The fill script types a code into the page's code
/// field from that world and never submits the form.
nonisolated struct VerificationPageScripts {
    /// The channel the detector posts to (a WebKit message handler, a CEF binding).
    static let channel = "cmuxVerify"
    /// The isolated world the scripts run in.
    static let world = "cmux-verify"

    /// The detector. `post` sends `report` (an object) to Swift; `ready` is true once the
    /// channel exists (CEF adds its binding after the world exists). It checks at load, then
    /// on DOM changes at most once a second, reports once per document, and stops after
    /// 10 minutes (the offer window). While the page is hidden its changes are only noted:
    /// it is checked once when it shows again, so a hidden page costs no timer and no layout.
    static func detectorScript(post: String, ready: String = "true") -> String {
        """
        (() => {
          if (window !== window.top || !/^https:$/.test(location.protocol)) return;
          const phrases = /(we (just )?sent|we('ve| have) (just )?(sent|emailed)|check your (email|inbox)|sent (you )?(a|an) (code|link|email)|enter (the|your) (verification |security |one-time |sign-in |login )?code|verification code|verify your email|confirm your email|magic link|one-time (pass)?code)/i;
          // `changed`: the DOM changed while the page was hidden; it is looked at when it shows.
          let reported = false, pending = false, changed = false, last = 0, waitsForChannel = 0;
          const waits = () => {
            if (document.querySelector('input[autocomplete~="one-time-code" i]')) return true;
            const text = (document.body && document.body.innerText || '').slice(0, 20000);
            return phrases.test(text);
          };
          const send = () => {
            if (reported) return;
            // The channel comes with the world's binding: wait for it at most 10 s, not forever.
            if (!(\(ready))) { if (++waitsForChannel < 40) setTimeout(send, 250); return; }
            reported = true;
            observer.disconnect();
            const report = { waiting: true };
            \(post);
          };
          const check = () => {
            pending = false;
            if (document.visibilityState === 'hidden') { changed = true; return; }
            last = Date.now();
            if (!reported && waits()) send();
          };
          // A hidden page is one nobody types a code into: its changes (a clock, a feed) cost no
          // timer and no text read until it shows again.
          const schedule = () => {
            if (reported || pending) return;
            if (document.visibilityState === 'hidden') { changed = true; return; }
            pending = true;
            setTimeout(check, Math.max(0, 1000 - (Date.now() - last)));
          };
          document.addEventListener('visibilitychange', () => {
            if (document.visibilityState === 'hidden' || !changed) return;
            changed = false;
            schedule();
          });
          const observer = new MutationObserver(schedule);
          const start = () => {
            if (!document.documentElement) return;
            observer.observe(document.documentElement, { childList: true, subtree: true, characterData: true });
            check();
            setTimeout(() => observer.disconnect(), 600000);
          };
          if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start, { once: true });
          else start();
        })();
        """
    }

    /// True when `body` (a WebKit message body, or a CEF payload decoded from JSON) is a
    /// detector report.
    static func isWaitingReport(_ body: Any) -> Bool {
        if let text = body as? String, let data = text.data(using: .utf8) {
            return isWaitingReport((try? JSONSerialization.jsonObject(with: data)) as Any)
        }
        return (body as? [String: Any])?["waiting"] as? Bool == true
    }

    /// Types `code` into the page's code field: the focused text field, else the
    /// `autocomplete="one-time-code"` field, else the only visible empty text field; split over
    /// a row of one-character fields when the page uses one. It sets each value with the
    /// isolated world's own value setter and sends `input` and `change`, and never submits.
    /// Evaluates to true when it filled a field.
    static func fillScript(code: String) -> String {
        let literal = jsonStringLiteral(code)
        return """
        (() => {
          if (window !== window.top) return false;
          const code = \(literal);
          const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
          const fields = Array.from(document.querySelectorAll('input')).filter((el) => {
            const type = (el.type || 'text').toLowerCase();
            return ['text', 'tel', 'number', 'password', ''].includes(type) && !el.disabled && !el.readOnly && el.offsetParent !== null;
          });
          const put = (el, value) => {
            el.focus();
            setter.call(el, value);
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
          };
          const singles = fields.filter((el) => el.maxLength === 1);
          if (singles.length === code.length && code.length > 1) {
            singles.forEach((el, i) => put(el, code[i]));
            return true;
          }
          const active = document.activeElement;
          const target = (fields.includes(active) && active)
            || document.querySelector('input[autocomplete~="one-time-code" i]')
            || (fields.filter((el) => !el.value).length === 1 ? fields.find((el) => !el.value) : null);
          if (!target) return false;
          put(target, code);
          return true;
        })();
        """
    }

    /// `text` as a JavaScript string literal (JSON is a subset), with no way to end the script.
    private static func jsonStringLiteral(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text])) ?? Data("[\"\"]".utf8)
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}
