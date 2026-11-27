//! Secret redaction for push text (PR #24156 security review M2).
//!
//! A push's title, body, last lines and questions travel through the Worker
//! and APNs in plain text until payloads are sealed (PR B). A permission's
//! title is often the whole command (`curl -H "Authorization: Bearer …"`), and
//! an agent's last lines can echo a `.env`. Before anything leaves the Mac,
//! each word that looks like a credential becomes `[redacted]`: known token
//! prefixes, a value after `Bearer`/`Basic`, a `password=`-style assignment,
//! a PEM block, and long high-entropy runs. Ids (UUIDs) and 40-digit commit
//! hashes stay: they are what a person reads to know which thing is meant.

const MARK: &str = "[redacted]";

/// Token prefixes that are credentials on their own.
const PREFIXES: &[&str] = &[
    "sk-",
    "sk_live_",
    "sk_test_",
    "rk_live_",
    "ghp_",
    "gho_",
    "ghu_",
    "ghs_",
    "ghr_",
    "github_pat_",
    "glpat-",
    "xoxa-",
    "xoxb-",
    "xoxp-",
    "xoxs-",
    "xoxe-",
    "AKIA",
    "ASIA",
    "AIza",
    "ya29.",
    "npm_",
    "pypi-",
    "hf_",
];

/// Assignment keys whose value is a secret (`password=…`, `API_KEY: …`).
const SECRET_KEYS: &[&str] =
    &["password", "passwd", "pwd", "secret", "token", "apikey", "api_key", "key", "auth", "credential"];

/// Words after which the next word is a credential.
const SCHEMES: &[&str] = &["bearer", "basic"];

/// `text` with every credential-looking word replaced by `[redacted]`.
/// Whitespace between words is kept as it was.
pub fn redact(text: &str) -> String {
    if let Some(start) = text.find("-----BEGIN") {
        return format!("{}{MARK}", redact(&text[..start]));
    }
    let mut out = String::with_capacity(text.len());
    let mut redact_next = false;
    let mut rest = text;
    while !rest.is_empty() {
        let space = rest.find(|c: char| !c.is_whitespace()).unwrap_or(rest.len());
        out.push_str(&rest[..space]);
        rest = &rest[space..];
        if rest.is_empty() {
            break;
        }
        let end = rest.find(char::is_whitespace).unwrap_or(rest.len());
        let word = &rest[..end];
        rest = &rest[end..];
        let core = word.trim_matches(|c: char| {
            matches!(c, '"' | '\'' | '`' | ',' | ';' | '(' | ')' | '[' | ']' | '{' | '}')
        });
        if redact_next && !core.is_empty() {
            out.push_str(&word.replace(core, MARK));
            redact_next = false;
            continue;
        }
        redact_next = SCHEMES.iter().any(|s| core.eq_ignore_ascii_case(s));
        out.push_str(&redact_word(word, core));
    }
    out
}

fn redact_word(word: &str, core: &str) -> String {
    if core.is_empty() {
        return word.to_owned();
    }
    // `KEY=value`, `--password=value`, `token:value`.
    if let Some(split) = core.find(['=', ':']) {
        let (key, value) = (&core[..split], &core[split + 1..]);
        let key_lower = key.trim_start_matches('-').to_ascii_lowercase();
        let named = SECRET_KEYS
            .iter()
            .any(|k| key_lower == *k || key_lower.ends_with(&format!("_{k}")) || key_lower.ends_with(k));
        if named && !value.is_empty() && !value.starts_with("//") {
            return word.replace(core, &format!("{}{MARK}", &core[..=split]));
        }
        if !value.is_empty() && is_secret(value) {
            return word.replace(value, MARK);
        }
    }
    if is_secret(core) { word.replace(core, MARK) } else { word.to_owned() }
}

/// Whether one word (no whitespace) is a credential.
fn is_secret(word: &str) -> bool {
    if PREFIXES.iter().any(|p| word.starts_with(p) && word.len() >= p.len() + 12) {
        return true;
    }
    // A JWT: three base64url parts, the first a JSON header.
    if word.starts_with("eyJ") && word.matches('.').count() == 2 && word.len() >= 30 {
        return true;
    }
    high_entropy(word)
}

/// A long run of token characters with mixed classes and high entropy; not a
/// UUID, a commit hash or a path.
fn high_entropy(word: &str) -> bool {
    let token = |c: char| c.is_ascii_alphanumeric() || matches!(c, '+' | '/' | '=' | '_' | '-');
    if word.len() < 32 || !word.chars().all(token) || word.matches('/').count() > 1 {
        return false;
    }
    if is_uuid(word)
        || (word.len() == 40 && word.chars().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()))
    {
        return false;
    }
    let classes = [
        word.chars().any(|c| c.is_ascii_lowercase()),
        word.chars().any(|c| c.is_ascii_uppercase()),
        word.chars().any(|c| c.is_ascii_digit()),
    ];
    if classes.iter().filter(|c| **c).count() < 2 {
        return false;
    }
    let mut counts = [0u32; 128];
    for b in word.bytes() {
        counts[usize::from(b & 0x7f)] += 1;
    }
    let n = word.len() as f64;
    let entropy: f64 =
        counts.iter().filter(|c| **c > 0).map(|&c| -(f64::from(c) / n) * (f64::from(c) / n).log2()).sum();
    entropy >= 4.0
}

fn is_uuid(word: &str) -> bool {
    let parts: Vec<&str> = word.split('-').collect();
    parts.len() == 5
        && parts
            .iter()
            .zip([8, 4, 4, 4, 12])
            .all(|(p, n)| p.len() == n && p.chars().all(|c| c.is_ascii_hexdigit()))
}
