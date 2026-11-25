//! Secrets scoped to one chat (hq RFD "Sandboxing and lockdown for Cloud, AutoCloud and the app",
//! first slice: per-chat secret scoping).
//!
//! Leo, 2026-11-25: "security/sandboxing... how will that work? what about if someone wants to
//! lock down a vm? lock down their app?"
//!
//! A machine-wide secret (`~/.config/cmux/machine-secrets.env`, `login_env.rs`) reaches every
//! agent on the machine, so a prompt injection in one chat can read the token another chat was
//! given and send it out. A chat secret reaches one chat only:
//!
//! - The person sets it with `_acpmux/chat_secrets_set {sessionId, secrets: {NAME: value},
//!   ttlSeconds?}` from their own connection (`hub/person.rs`); an agent on the unix socket is
//!   refused, so one chat cannot plant a value in another. `_acpmux/chat_secrets_clear
//!   {sessionId}` drops them; `_acpmux/chat_secrets_list {sessionId}` answers names and
//!   seconds left, never a value.
//! - The value lives in this daemon's memory only, zeroed when dropped: never in a record, the
//!   store, a log, a reply or a file. It is given to the chat's agent in its environment when
//!   that agent starts ([`apply`], from `agent/command.rs`), and to no other session's.
//! - It expires: [`DEFAULT_TTL`] unless the person asks for less or more, at most [`MAX_TTL`].
//!   An expired value is dropped and is not given to the next start; a running agent keeps the
//!   environment it started with until it restarts. Purging the chat drops its values.
//! - Names are those a machine declaration may carry (`login_env::machine_env_name_allowed`):
//!   never a loader, PATH, HOME or a `CMUX_`/`ACPMUX_` name. A chat value wins over a
//!   machine-wide value of the same name for that chat.

use std::collections::{BTreeMap, HashMap};
use std::sync::{LazyLock, Mutex};
use std::time::{Duration, Instant};
use zeroize::Zeroizing;

/// How long a chat secret lives when the person names no TTL.
pub const DEFAULT_TTL: Duration = Duration::from_secs(60 * 60);
/// The longest a chat secret may live.
pub const MAX_TTL: Duration = Duration::from_secs(24 * 60 * 60);
/// Names one chat may hold.
pub const MAX_NAMES: usize = 32;
/// The largest value: 64 KiB.
pub const MAX_VALUE_BYTES: usize = 64 * 1024;
/// Chats holding secrets at once; past it the set is refused (never a silent drop).
pub const MAX_CHATS: usize = 4096;

struct Entry {
    value: Zeroizing<String>,
    until: Instant,
}

static STORE: LazyLock<Mutex<HashMap<String, BTreeMap<String, Entry>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

fn store() -> std::sync::MutexGuard<'static, HashMap<String, BTreeMap<String, Entry>>> {
    STORE.lock().unwrap_or_else(|e| e.into_inner())
}

/// Drops every expired value (and a chat left with none).
fn sweep(map: &mut HashMap<String, BTreeMap<String, Entry>>, now: Instant) {
    map.retain(|_, names| {
        names.retain(|_, e| e.until > now);
        !names.is_empty()
    });
}

/// Why a set was refused. Names the name, never the value.
#[derive(Debug, PartialEq, Eq)]
pub enum Refused {
    Name(String),
    Value(String),
    TooMany,
    Ttl,
    Full,
}

impl std::fmt::Display for Refused {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Name(n) => write!(
                f,
                "{n} can't be a chat secret: a name is letters, digits and _, never a loader, \
                 PATH, HOME or a CMUX_/ACPMUX_ name"
            ),
            Self::Value(n) => write!(f, "{n}'s value is empty, has a NUL or is over 64 KiB"),
            Self::TooMany => write!(f, "a chat holds at most {MAX_NAMES} secrets"),
            Self::Ttl => write!(f, "ttlSeconds is 1 to {}", MAX_TTL.as_secs()),
            Self::Full => write!(f, "this daemon holds secrets for {MAX_CHATS} chats already"),
        }
    }
}

/// Sets `pairs` for `session` (adding to, or replacing names of, what it holds), each living
/// `ttl` ([`DEFAULT_TTL`] when None). All or nothing. Returns the names the chat now holds.
pub fn set(
    session: &str,
    pairs: Vec<(String, Zeroizing<String>)>,
    ttl: Option<Duration>,
) -> Result<Vec<String>, Refused> {
    let ttl = ttl.unwrap_or(DEFAULT_TTL);
    if ttl.is_zero() || ttl > MAX_TTL {
        return Err(Refused::Ttl);
    }
    for (name, value) in &pairs {
        if !crate::login_env::machine_env_name_allowed(name) {
            return Err(Refused::Name(name.clone()));
        }
        if value.is_empty() || value.len() > MAX_VALUE_BYTES || value.contains('\0') {
            return Err(Refused::Value(name.clone()));
        }
    }
    let now = Instant::now();
    let mut map = store();
    sweep(&mut map, now);
    if !map.contains_key(session) && map.len() >= MAX_CHATS {
        return Err(Refused::Full);
    }
    let held = map.get(session);
    let after = pairs
        .iter()
        .map(|(n, _)| n.as_str())
        .chain(held.into_iter().flat_map(|h| h.keys().map(String::as_str)))
        .collect::<std::collections::BTreeSet<_>>()
        .len();
    if after > MAX_NAMES {
        return Err(Refused::TooMany);
    }
    let names = map.entry(session.to_owned()).or_default();
    for (name, value) in pairs {
        names.insert(name, Entry { value, until: now + ttl });
    }
    Ok(names.keys().cloned().collect())
}

/// Drops every secret `session` holds; how many there were.
pub fn clear(session: &str) -> usize {
    store().remove(session).map_or(0, |names| names.len())
}

/// The names `session` holds and the whole seconds each has left. Never a value.
pub fn list(session: &str) -> Vec<(String, u64)> {
    let now = Instant::now();
    let mut map = store();
    sweep(&mut map, now);
    map.get(session)
        .map(|names| {
            names.iter().map(|(n, e)| (n.clone(), e.until.saturating_duration_since(now).as_secs()))
        })
        .into_iter()
        .flatten()
        .collect()
}

/// The live values of `session`, for its agent's start only.
fn values(session: &str) -> Vec<(String, Zeroizing<String>)> {
    let now = Instant::now();
    let mut map = store();
    sweep(&mut map, now);
    map.get(session)
        .map(|names| names.iter().map(|(n, e)| (n.clone(), e.value.clone())).collect())
        .unwrap_or_default()
}

/// Gives the chat's own live secrets to the agent `cmd` starts for `session`; nothing for a
/// command that is no session's.
pub(crate) fn apply(cmd: &mut tokio::process::Command, session: Option<&str>) {
    let Some(session) = session else { return };
    for (name, value) in values(session) {
        cmd.env(name, value.as_str());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pair(n: &str, v: &str) -> (String, Zeroizing<String>) {
        (n.to_owned(), Zeroizing::new(v.to_owned()))
    }

    fn env_of(cmd: &tokio::process::Command, name: &str) -> Option<String> {
        cmd.as_std()
            .get_envs()
            .find(|(k, _)| k.to_str() == Some(name))
            .and_then(|(_, v)| v.map(|v| v.to_string_lossy().into_owned()))
    }

    #[test]
    fn a_chat_secret_reaches_its_own_chat_only_and_expires() {
        let (a, b) = ("chat-secrets-unit-a", "chat-secrets-unit-b");
        set(a, vec![pair("UNIT_TOKEN", "v-a")], None).unwrap();
        let mut own = tokio::process::Command::new("true");
        apply(&mut own, Some(a));
        assert_eq!(env_of(&own, "UNIT_TOKEN").as_deref(), Some("v-a"));
        let mut other = tokio::process::Command::new("true");
        apply(&mut other, Some(b));
        assert_eq!(env_of(&other, "UNIT_TOKEN"), None);
        let mut none = tokio::process::Command::new("true");
        apply(&mut none, None);
        assert_eq!(env_of(&none, "UNIT_TOKEN"), None);
        let listed = list(a);
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].0, "UNIT_TOKEN");
        assert!(listed[0].1 > DEFAULT_TTL.as_secs() - 60);
        assert_eq!(clear(a), 1);
        assert!(list(a).is_empty());

        set(a, vec![pair("UNIT_SHORT", "v")], Some(Duration::from_millis(30))).unwrap();
        std::thread::sleep(Duration::from_millis(60));
        let mut late = tokio::process::Command::new("true");
        apply(&mut late, Some(a));
        assert_eq!(env_of(&late, "UNIT_SHORT"), None);
        assert!(list(a).is_empty());
    }

    #[test]
    fn a_set_refuses_loader_and_cmux_names_bad_values_and_ttls() {
        let s = "chat-secrets-unit-refuse";
        for name in ["PATH", "LD_PRELOAD", "DYLD_INSERT_LIBRARIES", "ACPMUX_HOME", "CMUX_X", "a b"]
        {
            assert_eq!(set(s, vec![pair(name, "v")], None), Err(Refused::Name(name.to_owned())));
        }
        assert_eq!(set(s, vec![pair("OK_NAME", "")], None), Err(Refused::Value("OK_NAME".into())));
        assert_eq!(
            set(s, vec![pair("OK_NAME", "a\0b")], None),
            Err(Refused::Value("OK_NAME".into()))
        );
        assert_eq!(set(s, vec![pair("OK_NAME", "v")], Some(Duration::ZERO)), Err(Refused::Ttl));
        assert_eq!(set(s, vec![pair("OK_NAME", "v")], Some(MAX_TTL * 2)), Err(Refused::Ttl));
        let many = (0..=MAX_NAMES).map(|i| pair(&format!("N{i}"), "v")).collect();
        assert_eq!(set(s, many, None), Err(Refused::TooMany));
        // All or nothing: a refused set left nothing behind.
        assert!(list(s).is_empty());
    }
}
