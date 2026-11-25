//! The page the person's browser shows at the end of Sign in with ChatGPT, served by the
//! loopback listener at `/auth/callback`: a cmux-styled card (the look of cmux.com's own sign-in
//! confirmations, light and dark) that says what happened and hands the person back to cmux.
//!
//! The app names where "back to cmux" goes with a [`ReturnLink`] (`<its scheme>://settings`),
//! since only it knows the scheme its build registers. A signed-in or cancelled page opens it once
//! on load, so cmux comes forward with no click; the button opens it again. A failure stays on the
//! page so its reason can be read. A page never closes its own tab: browsers refuse
//! `window.close()` for a tab a script did not open.
//!
//! The page is self-contained: one inline style and one inline script, each allowed by its hash
//! in the `Content-Security-Policy`, and nothing loaded from anywhere.

use std::sync::OnceLock;

use base64::Engine as _;
use sha2::Digest as _;

/// What the sign-in came to, as the page says it.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Outcome<'a> {
    SignedIn,
    /// The person said no on ChatGPT's page (`error=access_denied`).
    Cancelled,
    /// Any other failure, by its stable code (`no_chatgpt_account`, `state_mismatch`, ...).
    Failed(&'a str),
}

impl<'a> Outcome<'a> {
    /// The page's outcome for a failure code: `access_denied` is the person's own cancel.
    pub fn failed(code: &'a str) -> Self {
        if code == "access_denied" { Self::Cancelled } else { Self::Failed(code) }
    }
}

/// The link back to the app: a `cmux` or `cmux-<build>` scheme, host `settings`, an optional
/// lowercase path, and nothing else (no user, port, query or fragment), so no caller can make the
/// page open a web address or another app.
#[derive(Debug, Clone, PartialEq)]
pub struct ReturnLink(String);

impl ReturnLink {
    /// The longest link accepted.
    const MAX: usize = 128;

    pub fn parse(text: &str) -> Option<Self> {
        if text.len() > Self::MAX {
            return None;
        }
        let (scheme, rest) = text.split_once("://")?;
        let build_ok = |b: &str| {
            !b.is_empty()
                && b.bytes().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'-')
        };
        let scheme_ok = scheme == "cmux" || scheme.strip_prefix("cmux-").is_some_and(build_ok);
        let path = rest.strip_prefix("settings")?;
        let path_ok = path.is_empty()
            || (path.starts_with('/')
                && path.bytes().all(|c| c.is_ascii_lowercase() || matches!(c, b'/' | b'-')));
        (scheme_ok && path_ok).then(|| Self(text.to_owned()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// What the page shows for `outcome`: its HTML, served with [`content_security_policy`].
pub fn render(outcome: Outcome<'_>, back: Option<&ReturnLink>) -> String {
    let (tone, title, body) = words(outcome);
    let icon = match tone {
        Tone::Done => ICON_DONE,
        Tone::Neutral => ICON_NEUTRAL,
        Tone::Problem => ICON_PROBLEM,
    };
    let reopens = !matches!(outcome, Outcome::Failed(_));
    let action = match back {
        Some(link) => format!(
            "<a class=\"button\" id=\"back\" href=\"{href}\"{auto}>Open cmux</a>\n      \
             <p class=\"hint\">{hint}</p>",
            href = escape(link.as_str()),
            auto = if reopens { " data-auto=\"1\"" } else { "" },
            hint = if reopens {
                "cmux should open now. You can close this tab."
            } else {
                "You can close this tab."
            },
        ),
        None => "<p class=\"hint\">You can close this tab and return to cmux.</p>".to_owned(),
    };
    let detail = match outcome {
        Outcome::Failed(code) => format!("\n      <p class=\"code\">Error: {}</p>", escape(code)),
        _ => String::new(),
    };
    format!(
        "<!doctype html>
<html lang=\"en\">
<head>
  <meta charset=\"utf-8\">
  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
  <meta name=\"referrer\" content=\"no-referrer\">
  <title>{title} · cmux</title>
  <style>{STYLE}</style>
</head>
<body>
  <header><div class=\"brand\">{MARK}<span class=\"name\">cmux</span><span class=\"divider\" aria-hidden=\"true\">/</span><span class=\"product\">ChatGPT</span></div></header>
  <main>
    <section class=\"card {tone}\" aria-labelledby=\"title\">
      <h1 id=\"title\"><span class=\"status\" aria-hidden=\"true\">{icon}</span><span>{title}</span></h1>
      <p class=\"body\">{body}</p>{detail}
      {action}
    </section>
  </main>
  <script>{SCRIPT}</script>
</body>
</html>",
        tone = tone.class(),
        title = escape(title),
        body = escape(body),
    )
}

/// The page's `Content-Security-Policy`: nothing but its own style and script, by hash.
pub fn content_security_policy() -> &'static str {
    static CSP: OnceLock<String> = OnceLock::new();
    CSP.get_or_init(|| {
        let hash = |text: &str| {
            base64::engine::general_purpose::STANDARD.encode(sha2::Sha256::digest(text))
        };
        format!(
            "default-src 'none'; style-src 'sha256-{}'; script-src 'sha256-{}'; \
             base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
            hash(STYLE),
            hash(SCRIPT)
        )
    })
}

#[derive(Clone, Copy)]
enum Tone {
    Done,
    Neutral,
    Problem,
}

impl Tone {
    fn class(self) -> &'static str {
        match self {
            Self::Done => "done",
            Self::Neutral => "neutral",
            Self::Problem => "problem",
        }
    }
}

fn words(outcome: Outcome<'_>) -> (Tone, &'static str, &'static str) {
    match outcome {
        Outcome::SignedIn => (
            Tone::Done,
            "Signed in with ChatGPT",
            "cmux can now use your ChatGPT plan. Head back to cmux to start a chat.",
        ),
        Outcome::Cancelled => (
            Tone::Neutral,
            "Sign-in cancelled",
            "ChatGPT was not connected. You can try again from cmux at any time.",
        ),
        Outcome::Failed("no_chatgpt_account") => (
            Tone::Problem,
            "No ChatGPT plan on this account",
            "This account has no ChatGPT plan cmux can use. Try again from cmux \
             with an account that has one.",
        ),
        Outcome::Failed("state_mismatch") => (
            Tone::Problem,
            "This sign-in has expired",
            "This page came from an older sign-in. Use the newest sign-in tab, \
             or start Sign in with ChatGPT again from cmux.",
        ),
        Outcome::Failed("network" | "discovery_failed") => (
            Tone::Problem,
            "cmux could not reach OpenAI",
            "Check your internet connection, then try again from cmux.",
        ),
        Outcome::Failed(_) => (
            Tone::Problem,
            "Sign-in did not finish",
            "Something went wrong while connecting ChatGPT. Try again from cmux.",
        ),
    }
}

fn escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            _ => out.push(c),
        }
    }
    out
}

/// The cmux mark (cmux.com's `cmux-icon.svg`, without its shadow filter).
const MARK: &str = "<svg class=\"mark\" viewBox=\"0 0 256 256\" aria-hidden=\"true\"><defs>\
<linearGradient id=\"cmux-chevron\" x1=\"91\" y1=\"128\" x2=\"179\" y2=\"128\" gradientUnits=\"userSpaceOnUse\">\
<stop offset=\"0\" stop-color=\"#12c7f5\"/><stop offset=\"0.52\" stop-color=\"#2d8cff\"/><stop offset=\"1\" stop-color=\"#6c5cff\"/>\
</linearGradient></defs><rect x=\"22\" y=\"20\" width=\"212\" height=\"216\" rx=\"44\" fill=\"#fff\" stroke=\"#e5e5e5\" stroke-width=\"6\"/>\
<path d=\"M91 65 L179 128 L91 191 L91 151 L139 128 L91 105 Z\" fill=\"url(#cmux-chevron)\"/></svg>";

const ICON_DONE: &str = "<svg viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2.5\" \
stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"m5 12 4 4 10-10\"/></svg>";
const ICON_NEUTRAL: &str = "<svg viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2.5\" \
stroke-linecap=\"round\"><path d=\"M6 12h12\"/></svg>";
const ICON_PROBLEM: &str = "<svg viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2.5\" \
stroke-linecap=\"round\"><path d=\"M12 7v6\"/><path d=\"M12 17h.01\"/></svg>";

/// cmux.com's callback page tokens (web/app/coderouter/auth/complete/page.module.css).
const STYLE: &str = "
:root{color-scheme:light dark;--bg:#fafafa;--text:#171717;--muted:#737373;--border:#e5e5e5;\
--done:#15803d;--neutral:#737373;--problem:#b45309;--button:#171717;--button-text:#fafafa;--button-down:#404040}
@media (prefers-color-scheme:dark){:root{--bg:#0a0a0a;--text:#ededed;--muted:#a3a3a3;--border:#262626;\
--done:#4ade80;--neutral:#a3a3a3;--problem:#fbbf24;--button:#ededed;--button-text:#0a0a0a;--button-down:#c4c4c4}}
*{box-sizing:border-box}
body{margin:0;min-height:100svh;background:var(--bg);color:var(--text);\
font-family:-apple-system,BlinkMacSystemFont,\"Segoe UI\",system-ui,sans-serif;-webkit-font-smoothing:antialiased}
header{border-bottom:1px solid var(--border)}
.brand{display:flex;align-items:center;gap:10px;max-width:1152px;height:48px;margin:0 auto;padding:0 24px;font-size:13px}
.mark{width:24px;height:24px}
.name{font-size:14px;font-weight:600;letter-spacing:-0.025em}
.divider{margin:0 4px;color:var(--border)}
.product{color:var(--muted)}
main{display:grid;place-items:center;min-height:calc(100svh - 49px);padding:48px 24px}
.card{width:100%;max-width:480px;padding-bottom:48px;text-align:center}
h1{display:flex;align-items:center;justify-content:center;gap:10px;margin:0;font-size:30px;font-weight:600;\
letter-spacing:-0.03em;line-height:1.25;text-wrap:balance}
.status{display:grid;place-items:center;flex-shrink:0;width:24px;height:24px;border-radius:50%;color:var(--bg)}
.status svg{width:14px;height:14px}
.done .status{background:var(--done)}
.neutral .status{background:var(--neutral)}
.problem .status{background:var(--problem)}
.body{max-width:360px;margin:12px auto 0;color:var(--muted);font-size:15px;line-height:1.6;text-wrap:pretty}
.code{margin:8px 0 0;color:var(--muted);font:12px ui-monospace,SFMono-Regular,Menlo,monospace}
.button{display:inline-block;margin-top:28px;padding:9px 18px;border-radius:8px;background:var(--button);\
color:var(--button-text);font-size:14px;font-weight:500;text-decoration:none}
.button:active{background:var(--button-down)}
.button:focus-visible{outline:2px solid #2d8cff;outline-offset:2px}
.hint{margin:16px 0 0;color:var(--muted);font-size:13px}
@media (max-width:480px){h1{font-size:26px}}
";

/// Drops the spent `?code=` from the address bar, then opens the way back to cmux once when the
/// page asks for it (`data-auto`).
const SCRIPT: &str = "
try{history.replaceState(null,'',location.pathname)}catch(e){}
var back=document.getElementById('back');
if(back&&back.dataset.auto){location.href=back.href}
";

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_return_link_is_only_a_cmux_settings_link() {
        for good in
            ["cmux://settings", "cmux-dev://settings/models", "cmux-dev-my-tag-2://settings"]
        {
            assert_eq!(ReturnLink::parse(good).map(|l| l.0), Some(good.to_owned()), "{good}");
        }
        for bad in [
            "https://settings",
            "javascript://settings",
            "cmuxx://settings",
            "cmux-://settings",
            "cmux-Dev://settings",
            "cmux://tab/tab_0123",
            "cmux://settings.evil",
            "cmux://settings@evil",
            "cmux://settings:80",
            "cmux://settings?x=1",
            "cmux://settings#x",
            "cmux://settings/\"><script>",
            "cmux://settings/Models",
            "",
        ] {
            assert_eq!(ReturnLink::parse(bad), None, "{bad}");
        }
        assert_eq!(ReturnLink::parse(&format!("cmux://settings/{}", "a".repeat(128))), None);
    }

    #[test]
    fn a_signed_in_page_opens_cmux_and_a_failed_one_waits_to_be_read() {
        let back = ReturnLink::parse("cmux-dev://settings").unwrap();
        let done = render(Outcome::SignedIn, Some(&back));
        assert!(done.contains("Signed in with ChatGPT"));
        assert!(done.contains("href=\"cmux-dev://settings\" data-auto=\"1\""));
        let cancelled = render(Outcome::failed("access_denied"), Some(&back));
        assert!(cancelled.contains("Sign-in cancelled"));
        assert!(cancelled.contains("data-auto=\"1\""));
        assert!(!cancelled.contains("Error:"));
        let failed = render(Outcome::failed("no_chatgpt_account"), Some(&back));
        assert!(failed.contains("No ChatGPT plan on this account"));
        assert!(failed.contains("Error: no_chatgpt_account"));
        assert!(failed.contains("href=\"cmux-dev://settings\""));
        assert!(!failed.contains("data-auto"), "a failure is read, not left at once");
        let bare = render(Outcome::SignedIn, None);
        assert!(!bare.contains("id=\"back\""));
        assert!(bare.contains("return to cmux"));
    }

    #[test]
    fn a_failure_code_is_escaped() {
        let page = render(Outcome::Failed("<b>x</b>"), None);
        assert!(page.contains("Error: &lt;b&gt;x&lt;/b&gt;"));
        assert!(!page.contains("<b>x</b>"));
    }

    #[test]
    fn the_policy_allows_exactly_the_page_s_own_style_and_script() {
        let page = render(Outcome::SignedIn, None);
        let csp = content_security_policy();
        let hash =
            |t: &str| base64::engine::general_purpose::STANDARD.encode(sha2::Sha256::digest(t));
        assert!(page.contains(&format!("<style>{STYLE}</style>")));
        assert!(page.contains(&format!("<script>{SCRIPT}</script>")));
        assert!(csp.contains(&format!("style-src 'sha256-{}'", hash(STYLE))));
        assert!(csp.contains(&format!("script-src 'sha256-{}'", hash(SCRIPT))));
        assert!(csp.starts_with("default-src 'none'"));
    }
}
