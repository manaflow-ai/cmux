//! Reading an agent session link: the web page `https://cmux.com/deeplink/agent?harness=&session=
//! &host=&name=&message=` that every PR footer carries, and the native `cmux://agent/<harness>/
//! <session>?...` cmux NEXT opens. `schemas/deeplinks/agent-link.json` states both; its vectors
//! run here too, so this reader cannot drift from the page or the app. `acpmux resolve`
//! (`hub/locate.rs`) finds the session a link names.

/// What a link names. `session` is the harness's own session id (Claude's, Codex's), which
/// acpmux keeps as a session's `agentSessionId`; the rest are hints.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct AgentLink {
    pub harness: String,
    pub session: String,
    pub host: Option<String>,
    pub name: Option<String>,
    pub message: Option<String>,
    pub machine: Option<String>,
}

impl AgentLink {
    /// The web link, its query in the schema's `queryParams` order; None when the harness or
    /// session is not one the schema takes. A hint it does not take is left out, not escaped.
    pub fn web_url(&self) -> Option<String> {
        if !is_harness(&self.harness) || !is_id(&self.session, 256, ":") {
            return None;
        }
        let mut url =
            format!("https://cmux.com{WEB_PATH}?harness={}&session={}", self.harness, self.session);
        let hints = [
            ("host", &self.host, is_id(self.host.as_deref().unwrap_or_default(), 64, "")),
            ("name", &self.name, is_id(self.name.as_deref().unwrap_or_default(), 64, "")),
            ("message", &self.message, is_id(self.message.as_deref().unwrap_or_default(), 200, "")),
            ("machine", &self.machine, is_machine(self.machine.as_deref().unwrap_or_default())),
        ];
        for (key, value, ok) in hints {
            if let (Some(value), true) = (value, ok) {
                url.push_str(&format!("&{key}={value}"));
            }
        }
        Some(url)
    }
}

const WEB_PATH: &str = "/deeplink/agent";

/// What ends a URL in text: whitespace, or what markdown, HTML or a quote puts after one.
const END: &str = r#"\s)>\]"'`"#;

/// The web link: `cmux.com` (or `www.`), an optional locale (`/zh-CN`), then exactly
/// `/deeplink/agent`, its query, and the end of the URL. Group 1 is the query. None only if the
/// pattern did not compile, which `the_schema_vectors_read_the_same_here` would show.
static WEB: std::sync::LazyLock<Option<regex::Regex>> = std::sync::LazyLock::new(|| {
    regex::Regex::new(&format!(
        r"(?:^|[{END}(<\[])https://(?:www\.)?cmux\.com(?:/[a-z]{{2}}(?:-[A-Z]{{2}})?)?{WEB_PATH}/?(?:\?([^{END}]*))?(?:$|[{END}])"
    ))
    .ok()
});

/// The native link, at the start of the text or after what may stand before a URL. Group 1 is
/// everything after `cmux://agent/`.
static NATIVE: std::sync::LazyLock<Option<regex::Regex>> = std::sync::LazyLock::new(|| {
    regex::Regex::new(&format!(r"(?:^|[{END}(<\[])cmux://agent(?:/([^{END}]*))?(?:$|[{END}])")).ok()
});

/// The link in `text`, which may be the bare URL or a line that carries one (a PR footer's
/// markdown `[big-red](https://...)`). None when `text` holds no agent link (a URL on another
/// host or path, a session name); an error naming what is wrong when it holds one that names no
/// session.
pub fn find(text: &str) -> Option<Result<AgentLink, String>> {
    if let Some(found) = NATIVE.as_ref().and_then(|re| re.captures(text)) {
        let rest = found.get(1).map_or("", |m| m.as_str());
        let (path, query) = rest.split_once('?').unwrap_or((rest, ""));
        let mut segments = path.split('/');
        let (harness, session) = (segments.next().unwrap_or(""), segments.next());
        if segments.next().is_some() {
            return Some(Err(format!("cmux://agent/{path} has more than <harness>/<session>")));
        }
        let required =
            [("harness", Some(harness)), ("session", session)].map(|(k, v)| (k, v.map(decode)));
        return Some(build(required, query));
    }
    let query = WEB.as_ref()?.captures(text)?.get(1).map_or("", |m| m.as_str());
    let named = |key: &str| pairs(query).into_iter().filter(|(k, _)| k == key).collect::<Vec<_>>();
    let mut required = Vec::new();
    for key in ["harness", "session"] {
        let mut values = named(key);
        if values.len() > 1 {
            return Some(Err(format!("the link names {key} more than once")));
        }
        required.push((key, values.pop().map(|(_, v)| v)));
    }
    Some(build([required[0].clone(), required[1].clone()], query))
}

fn build(required: [(&str, Option<Option<String>>); 2], query: &str) -> Result<AgentLink, String> {
    let mut link = AgentLink::default();
    for (key, value) in required {
        let value = match value {
            None | Some(None) => return Err(format!("the link names no {key}")),
            Some(Some(v)) if v.is_empty() => return Err(format!("the link names no {key}")),
            Some(Some(v)) => v,
        };
        let ok = if key == "harness" { is_harness(&value) } else { is_id(&value, 256, ":") };
        if !ok {
            return Err(format!("the link's {key} {value:?} is not a {key} id"));
        }
        if key == "harness" { link.harness = value } else { link.session = value }
    }
    // Optional hints: a repeated, empty or unusable one names nothing (the schema's rule).
    let seen = pairs(query);
    let hint = |key: &str, ok: &dyn Fn(&str) -> bool| -> Option<String> {
        let mut values = seen.iter().filter(|(k, _)| k == key);
        let first = values.next()?;
        if values.next().is_some() {
            return None;
        }
        first.1.clone().filter(|v| ok(v))
    };
    link.host = hint("host", &|v| is_id(v, 64, ""));
    link.name = hint("name", &|v| is_id(v, 64, ""));
    link.message = hint("message", &|v| is_id(v, 200, ""));
    link.machine = hint("machine", &is_machine);
    Ok(link)
}

/// `k=v` pairs of a query, each decoded (`&amp;` read as `&`, a link copied from rendered HTML);
/// a value that is not UTF-8 once decoded is None.
fn pairs(query: &str) -> Vec<(String, Option<String>)> {
    query
        .replace("&amp;", "&")
        .split('&')
        .filter(|p| !p.is_empty())
        .map(|p| {
            let (k, v) = p.split_once('=').unwrap_or((p, ""));
            (decode(k).unwrap_or_default(), decode(v))
        })
        .collect()
}

/// Percent-decoding; None for a bad escape or bytes that are not UTF-8.
fn decode(s: &str) -> Option<String> {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let hex = s.get(i + 1..i + 3)?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

/// `^[a-z0-9-]{1,64}$`
fn is_harness(v: &str) -> bool {
    (1..=64).contains(&v.len())
        && v.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
}

/// `^machine_[0-9a-f]{32}$`
fn is_machine(v: &str) -> bool {
    v.strip_prefix("machine_").is_some_and(|hex| {
        hex.len() == 32 && hex.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    })
}

/// `^(?!\.+$)[A-Za-z0-9._<extra>-]{1,max}$`
fn is_id(v: &str, max: usize, extra: &str) -> bool {
    (1..=max).contains(&v.len())
        && !v.bytes().all(|b| b == b'.')
        && v.bytes().all(|b| {
            b.is_ascii_alphanumeric()
                || matches!(b, b'.' | b'_' | b'-')
                || extra.as_bytes().contains(&b)
        })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    const SCHEMA: &str = include_str!("../../../../schemas/deeplinks/agent-link.json");

    fn fields(link: &AgentLink) -> Value {
        let mut v = serde_json::json!({"harness": link.harness, "session": link.session});
        for (k, f) in [
            ("host", &link.host),
            ("name", &link.name),
            ("message", &link.message),
            ("machine", &link.machine),
        ] {
            if let Some(f) = f {
                v[k] = Value::String(f.clone());
            }
        }
        v
    }

    /// Every vector of the shared schema: the web form and the native form read the same fields,
    /// and a link the page and the app refuse is refused here.
    #[test]
    fn the_schema_vectors_read_the_same_here() {
        assert!(WEB.is_some() && NATIVE.is_some(), "a link pattern does not compile");
        let schema: Value = serde_json::from_str(SCHEMA).unwrap();
        for v in schema["vectors"].as_array().unwrap() {
            let name = v["name"].as_str().unwrap();
            let mut forms = Vec::new();
            if let Some(web) = v["web"].as_str() {
                forms.push(format!("https://cmux.com{WEB_PATH}?{web}"));
            }
            if let Some(link) = v["link"].as_str() {
                forms.push(link.to_owned());
            }
            for form in forms {
                let got = find(&form).unwrap_or_else(|| panic!("{name}: no link in {form}"));
                match (&v["fields"], got) {
                    (Value::Null, Err(_)) => {}
                    (Value::Null, Ok(link)) => panic!("{name}: {form} read as {link:?}"),
                    (want, Ok(link)) => assert_eq!(&fields(&link), want, "{name}: {form}"),
                    (_, Err(e)) => panic!("{name}: {form} refused: {e}"),
                }
            }
        }
    }

    #[test]
    fn a_pr_footer_line_carries_its_link() {
        let line = "Agent session: [big-red](https://cmux.com/deeplink/agent?harness=claude&session=01a16c8c-54ec-71b2-a0fa-125d1404dd72&host=big-red)";
        let link = find(line).unwrap().unwrap();
        assert_eq!(link.harness, "claude");
        assert_eq!(link.session, "01a16c8c-54ec-71b2-a0fa-125d1404dd72");
        assert_eq!(link.host.as_deref(), Some("big-red"));
        // A localized page and an HTML-escaped query read the same.
        let html = "https://cmux.com/en/deeplink/agent?harness=codex&amp;session=s%3A1&amp;host=hb";
        let link = find(html).unwrap().unwrap();
        assert_eq!((link.harness.as_str(), link.session.as_str()), ("codex", "s:1"));
        assert_eq!(link.host.as_deref(), Some("hb"));
    }

    #[test]
    fn a_written_link_reads_back_and_leaves_out_what_the_schema_refuses() {
        let link = AgentLink {
            harness: "claude".into(),
            session: "s:1".into(),
            host: Some("big-red".into()),
            name: Some("two words".into()),
            ..Default::default()
        };
        let url = link.web_url().unwrap();
        assert_eq!(url, "https://cmux.com/deeplink/agent?harness=claude&session=s:1&host=big-red");
        assert_eq!(find(&url).unwrap().unwrap(), AgentLink { name: None, ..link });
        assert!(AgentLink { harness: "Claude".into(), ..Default::default() }.web_url().is_none());
    }

    #[test]
    fn text_without_a_link_is_not_one() {
        assert!(find("https://cmux.com/deeplink/agent").unwrap().is_err());
        for not in [
            "builder/review",
            "01a16c8c-54ec-71b2-a0fa-125d1404dd72",
            "builder/deeplink/agent?harness=claude&session=s1",
            "https://cmux.com/deeplink/agentx?harness=claude&session=s1",
            "https://evil.com/deeplink/agent?harness=claude&session=s1",
            "https://cmux.com.evil.com/deeplink/agent?harness=claude&session=s1",
            "https://cmux.com/x/y/deeplink/agent?harness=claude&session=s1",
            "http://cmux.com/deeplink/agent?harness=claude&session=s1",
            "notcmux://agent/claude/s1",
            "see https://evil.com/?u=cmux://agent/claude/s1",
        ] {
            assert!(find(not).is_none(), "{not}");
        }
        // In markdown, angle brackets or quotes it still reads.
        for text in [
            "<cmux://agent/claude/s1>",
            "(https://cmux.com/zh-CN/deeplink/agent?harness=claude&session=s1)",
            "\"https://www.cmux.com/deeplink/agent/?harness=claude&session=s1\"",
        ] {
            assert_eq!(find(text).unwrap().unwrap().session, "s1", "{text}");
        }
    }
}
