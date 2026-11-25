import Foundation

/// Asks a finished page whether it wants the person to sign in, for the Import Cookies card
/// (`BrowserImportOfferService`, Lawrence 2026-11-09: the card shows only where a sign-in would come over).
///
/// A sign-in page has a password field, a field the page marks for a user name or a passkey, or an
/// email field on a sign-in address (`/login`, `/signin`, `/auth/…`, `/sso`, `accounts.…`: an
/// email-first page such as ChatGPT's). Many sign-in pages are apps that draw their form after the
/// load ends (Discord, Figma and Cloudflare on 2026-11-20: no field at load end, one 4 s later), so
/// a page with none yet is watched by a `MutationObserver` in an isolated world, at most one check
/// per 100 ms, until a field appears, the page goes or ``watchMilliseconds`` pass. It reads only the
/// page's DOM, never another browser's data.
///
/// ```swift
/// if await BrowserSignInProbe().asksSignIn(entry.tab) { offer(in: entry) }
/// ```
@MainActor
public struct BrowserSignInProbe {
    /// How long a page is watched for a form it draws later: under the engines' 5 s evaluation bound.
    public let watchMilliseconds: Int

    /// - Parameter watchMilliseconds: The watch's bound (4 s by default; tests may shorten it).
    public init(watchMilliseconds: Int = 4000) {
        self.watchMilliseconds = watchMilliseconds
    }

    /// The page's answer, true or false; false when it gave none (closed, navigated, timed out).
    public func asksSignIn(_ tab: any BrowserTab) async -> Bool {
        let answer: BrowserJSValue?
        if let webKit = tab as? WebKitTab {
            // WebKit's gesture-free evaluate returns a promise unawaited; its async function call awaits it.
            answer = try? await webKit.callFunction("return await \(script);", world: .isolated, gesture: .cmux)
        } else {
            answer = try? await tab.evaluate(script, world: .isolated, gesture: .cmux)  // Chromium awaits the promise
        }
        return answer == .bool(true)
    }

    /// The probe: a promise that resolves to true or false.
    var script: String {
        """
        new Promise((resolve) => {
          const strong = 'input[type=password], input[autocomplete~="current-password"], input[autocomplete~="username"], input[autocomplete~="webauthn"]';
          const signInAddress = /(^|[\\/._-])(log[-_]?in|sign[-_]?in|auth|sso)([\\/._-]|$)/i.test(location.pathname)
            || /^(login|signin|auth|accounts|sso|id)\\./i.test(location.hostname);
          const asks = () => !!document.querySelector(strong)
            || (signInAddress && !!document.querySelector('input[type=email], input[autocomplete~="email"]'));
          if (asks()) return resolve(true);
          let done = false, queued = false, timer = 0;
          const observer = new MutationObserver(() => {
            if (queued || done) return;
            queued = true;
            setTimeout(() => { queued = false; if (asks()) finish(true); }, 100);
          });
          const gone = () => finish(false);
          function finish(answer) {
            if (done) return;
            done = true;
            observer.disconnect();
            clearTimeout(timer);
            removeEventListener('pagehide', gone);
            resolve(answer);
          }
          observer.observe(document, { childList: true, subtree: true, attributes: true, attributeFilter: ['type', 'autocomplete'] });
          addEventListener('pagehide', gone);
          timer = setTimeout(gone, \(watchMilliseconds));
        })
        """
    }
}
