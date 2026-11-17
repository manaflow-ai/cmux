//! A Cloud machine's model route for every agent acpmux starts there.
//!
//! The image bakes `/etc/cmux/model-plane.env` (root-owned, the same bytes on every machine,
//! web/services/coderouter/vmGuestEnv.ts): base URLs at the coderouter edge alias
//! (`https://coderouter.cmux.internal`) and the public placeholder key. The machine's edge rule
//! (cmux-platform CoderouterEdge) adds the per-machine token, so the guest holds no provider
//! login and the Mac copies none to it.
//!
//! A login shell sources that file (agent-config.sh), but it sets Claude's pair aside for its
//! terminal launcher, and acpmux's own process (a systemd user unit) never sources it. A
//! remote-origin launch (`apply_remote_tokio`) gets no provider variables at all. So an agent
//! acpmux started had no base URL and no key: Claude said "Not logged in" and never reached the
//! edge. Every harness spawn on a Cloud machine therefore gets the file's variables for each name
//! it does not already have: the daemon's own env, the login shell, a profile, preset, session
//! or bound route still win, and a route's unset list still removes them.
//!
//! Only the file's fixed names are read, never a token: a value that looks like one (a route
//! token or a JWT) drops the file, as does a file that is not root's or is writable by others.

use std::collections::BTreeMap;
use std::path::Path;

/// Where the image keeps the model route.
pub const PLANE_FILE: &str = "/etc/cmux/model-plane.env";
/// The public placeholder agents send; the edge swaps in the machine's token.
pub const PLACEHOLDER: &str = "cmux-vm-edge-placeholder";
/// The names the file may set; anything else in it is ignored.
pub const KEYS: [&str; 5] = [
    "OPENAI_BASE_URL",
    "OPENAI_API_KEY",
    "CMUX_CODEROUTER_URL",
    "ANTHROPIC_BASE_URL",
    "ANTHROPIC_API_KEY",
];

/// Why the file gave no route.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Problem {
    Missing,
    /// Not a regular file owned by root and writable only by it.
    Untrusted,
    /// A token-shaped value, a base URL that is not https, or no base URL at all.
    Invalid,
}

impl Problem {
    pub fn word(self) -> &'static str {
        match self {
            Problem::Missing => "missing",
            Problem::Untrusted => "untrusted",
            Problem::Invalid => "invalid",
        }
    }
}

/// `export NAME='value'` lines as `renderVmGuestModelPlaneEnvFile` writes them (a `'\''` inside
/// a value is a quote). Lines in any other shape, and names outside [`KEYS`], are skipped.
pub fn parse(text: &str) -> BTreeMap<String, String> {
    let mut out = BTreeMap::new();
    for line in text.lines() {
        let line = line.trim();
        let Some(rest) = line.strip_prefix("export ") else { continue };
        let Some((name, quoted)) = rest.split_once('=') else { continue };
        if !KEYS.contains(&name) {
            continue;
        }
        let Some(value) = unquote(quoted) else { continue };
        if !value.is_empty() {
            out.insert(name.to_owned(), value);
        }
    }
    out
}

fn unquote(quoted: &str) -> Option<String> {
    let inner = quoted.strip_prefix('\'')?.strip_suffix('\'')?;
    // A quote other than the `'\''` escape is not this file's shape.
    (!inner.replace("'\\''", "").contains('\'')).then(|| inner.replace("'\\''", "'"))
}

fn token_shaped(value: &str) -> bool {
    let jwt = value.split('.').count() == 3 && value.starts_with("eyJ");
    value.contains("crt_") || jwt || value.contains("sk-ant-") || value.contains("sk-proj-")
}

/// The file's variables, checked: every base URL https, no token-shaped value, both base URLs there.
pub fn validate(vars: BTreeMap<String, String>) -> Result<BTreeMap<String, String>, Problem> {
    if vars.values().any(|v| token_shaped(v)) {
        return Err(Problem::Invalid);
    }
    let https = |k: &str| vars.get(k).is_some_and(|v| v.starts_with("https://"));
    if !https("ANTHROPIC_BASE_URL") || !https("OPENAI_BASE_URL") {
        return Err(Problem::Invalid);
    }
    if vars.get("CMUX_CODEROUTER_URL").is_some_and(|v| !v.starts_with("https://")) {
        return Err(Problem::Invalid);
    }
    Ok(vars)
}

/// The route in `path`. `require_root`: the file must be root's and writable only by root (the
/// image's), never a symlink.
pub fn read_at(path: &Path, require_root: bool) -> Result<BTreeMap<String, String>, Problem> {
    let meta = match std::fs::symlink_metadata(path) {
        Ok(meta) => meta,
        Err(_) => return Err(Problem::Missing),
    };
    if !meta.is_file() || meta.len() > 64 * 1024 {
        return Err(Problem::Untrusted);
    }
    #[cfg(unix)]
    if require_root {
        use std::os::unix::fs::MetadataExt as _;
        if meta.uid() != 0 || meta.mode() & 0o022 != 0 {
            return Err(Problem::Untrusted);
        }
    }
    #[cfg(not(unix))]
    let _ = require_root;
    let text = std::fs::read_to_string(path).map_err(|_| Problem::Untrusted)?;
    validate(parse(&text))
}

/// This machine's route: the image file's on a Cloud VM whose edge host resolves, nothing
/// elsewhere. Read on every call (a few hundred bytes), so a `cmux host update` that rewrites it
/// applies to the next spawn.
///
/// The image bakes the file on every machine, but only a backend that installs the machine's
/// edge rule makes `coderouter.cmux.internal` resolve (development only; staging and production
/// send no rule, plans/cmux-next/vm-coderouter-edge.md). Filling the pair there points every
/// agent at a host that does not exist, over the person's own sign-in ("Can't reach the API
/// server (ENOTFOUND)", Cloud journey on staging after #40159). So a route whose host does not
/// resolve is no route, as `claude_cloud_auth::team_pair` and `codex_cloud_auth` already rule.
pub fn machine_plane() -> BTreeMap<String, String> {
    if !crate::cloud_host::is_cloud_vm() {
        return BTreeMap::new();
    }
    let plane = read_at(Path::new(PLANE_FILE), true).unwrap_or_default();
    reachable(plane, edge_resolves)
}

/// `plane`, or nothing when one of its base URLs' hosts does not resolve (`resolves`).
pub fn reachable(
    plane: BTreeMap<String, String>,
    resolves: impl Fn(&str) -> bool,
) -> BTreeMap<String, String> {
    let mut hosts: Vec<&str> = ["ANTHROPIC_BASE_URL", "OPENAI_BASE_URL", "CMUX_CODEROUTER_URL"]
        .iter()
        .filter_map(|k| plane.get(*k))
        .filter_map(|url| host_of(url))
        .collect();
    hosts.sort_unstable();
    hosts.dedup();
    if hosts.is_empty() || !hosts.iter().all(|h| resolves(h)) {
        return BTreeMap::new();
    }
    plane
}

/// The host (and port, if any) of an `https://` URL.
fn host_of(url: &str) -> Option<&str> {
    let rest = url.strip_prefix("https://")?;
    let host = rest.split(['/', '?', '#']).next()?;
    let host = host.rsplit_once('@').map_or(host, |(_, h)| h);
    (!host.is_empty()).then_some(host)
}

/// How long one spawn waits for the resolver before it starts without the route.
const RESOLVE_WAIT: std::time::Duration = std::time::Duration::from_secs(5);
/// How long an answer is reused, so a burst of spawns resolves once.
const RESOLVE_REUSE: std::time::Duration = std::time::Duration::from_secs(60);

/// Whether `host` resolves, answered from a short cache. A resolver that gives no answer within
/// [`RESOLVE_WAIT`] counts as unreachable for this spawn and is not cached.
fn edge_resolves(host: &str) -> bool {
    use std::sync::Mutex;
    use std::time::Instant;
    static CACHE: Mutex<Option<(String, Instant, bool)>> = Mutex::new(None);
    if let Some((h, at, ok)) = CACHE.lock().unwrap_or_else(|e| e.into_inner()).as_ref()
        && h == host
        && at.elapsed() < RESOLVE_REUSE
    {
        return *ok;
    }
    let target = if host.contains(':') { host.to_owned() } else { format!("{host}:443") };
    let (tx, rx) = std::sync::mpsc::channel();
    let spawned = std::thread::Builder::new().name("model-plane-resolve".into()).spawn(move || {
        let ok = std::net::ToSocketAddrs::to_socket_addrs(&target)
            .map(|mut a| a.next().is_some())
            .unwrap_or(false);
        let _ = tx.send(ok);
    });
    if spawned.is_err() {
        return false;
    }
    match rx.recv_timeout(RESOLVE_WAIT) {
        Ok(ok) => {
            *CACHE.lock().unwrap_or_else(|e| e.into_inner()) =
                Some((host.to_owned(), Instant::now(), ok));
            ok
        }
        Err(_) => false,
    }
}

/// The `plane` variables for each name `present` says the child does not have yet.
pub fn missing(
    plane: &BTreeMap<String, String>,
    present: impl Fn(&str) -> bool,
) -> Vec<(String, String)> {
    plane.iter().filter(|(k, _)| !present(k)).map(|(k, v)| (k.clone(), v.clone())).collect()
}

/// Whether `cmd`'s child gets `key`: set on it, or inherited from this process (`inherits`)
/// and not removed.
fn has(cmd: &std::process::Command, inherits: bool, key: &str) -> bool {
    match cmd.get_envs().find(|(k, _)| *k == std::ffi::OsStr::new(key)) {
        Some((_, value)) => value.is_some_and(|v| !v.is_empty()),
        None => inherits && std::env::var_os(key).is_some_and(|v| !v.is_empty()),
    }
}

/// Adds the machine's route to a harness command. `inherits`: the command was not `env_clear`ed.
pub fn fill_std(cmd: &mut std::process::Command, inherits: bool) {
    let plane = machine_plane();
    if plane.is_empty() {
        return;
    }
    let add = missing(&plane, |key| has(cmd, inherits, key));
    cmd.envs(add);
}

/// Same, for tokio's process builder.
pub fn fill_tokio(cmd: &mut tokio::process::Command, inherits: bool) {
    let plane = machine_plane();
    if plane.is_empty() {
        return;
    }
    let add = missing(&plane, |key| has(cmd.as_std(), inherits, key));
    cmd.envs(add);
}

/// Adds the machine's route to an environment computed without spawning (sign-in checks).
pub fn fill_map(env: &mut BTreeMap<String, String>) {
    for (key, value) in missing(&machine_plane(), |key| env.get(key).is_some_and(|v| !v.is_empty()))
    {
        env.insert(key, value);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const BAKED: &str = "# generated by cmux; the same for every machine; managed, do not edit\n\
        export OPENAI_BASE_URL='https://coderouter.cmux.internal/v1'\n\
        export OPENAI_API_KEY='cmux-vm-edge-placeholder'\n\
        export CMUX_CODEROUTER_URL='https://coderouter.cmux.internal'\n\
        export ANTHROPIC_BASE_URL='https://coderouter.cmux.internal'\n\
        export ANTHROPIC_API_KEY='cmux-vm-edge-placeholder'\n";

    #[test]
    fn the_baked_file_is_the_route() {
        let vars = validate(parse(BAKED)).unwrap();
        assert_eq!(vars.len(), 5);
        assert_eq!(vars["ANTHROPIC_BASE_URL"], "https://coderouter.cmux.internal");
        assert_eq!(vars["ANTHROPIC_API_KEY"], PLACEHOLDER);
        assert_eq!(vars["OPENAI_BASE_URL"], "https://coderouter.cmux.internal/v1");
    }

    #[test]
    fn other_names_and_shapes_are_skipped() {
        let text = format!(
            "{BAKED}export PATH='/evil'\nexport CLAUDE_CODE_OAUTH_TOKEN='x'\nOPENAI_MODEL=gpt\nexport OPENAI_API_KEY=unquoted\n"
        );
        let vars = parse(&text);
        assert!(!vars.contains_key("PATH"));
        assert!(!vars.contains_key("CLAUDE_CODE_OAUTH_TOKEN"));
        assert_eq!(vars["OPENAI_API_KEY"], PLACEHOLDER);
    }

    #[test]
    fn a_token_or_a_plain_http_route_drops_the_file() {
        for bad in [
            BAKED.replace("cmux-vm-edge-placeholder'\nexport CMUX", "crt_abc.def'\nexport CMUX"),
            BAKED.replace("cmux-vm-edge-placeholder'\nexport CMUX", "eyJa.eyJb.sig'\nexport CMUX"),
            BAKED.replace(
                "'https://coderouter.cmux.internal'\nexport ANTHROPIC_API",
                "'http://coderouter.cmux.internal'\nexport ANTHROPIC_API",
            ),
        ] {
            assert_eq!(validate(parse(&bad)), Err(Problem::Invalid), "{bad}");
        }
        let no_claude: String = BAKED
            .lines()
            .filter(|l| !l.contains("ANTHROPIC_BASE_URL"))
            .collect::<Vec<_>>()
            .join("\n");
        assert_eq!(validate(parse(&no_claude)), Err(Problem::Invalid));
    }

    #[test]
    fn a_file_others_can_write_or_a_symlink_is_untrusted() {
        let dir = std::env::temp_dir().join(format!("acpmux-plane-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("model-plane.env");
        assert_eq!(read_at(&file, false), Err(Problem::Missing));
        std::fs::write(&file, BAKED).unwrap();
        assert_eq!(read_at(&file, false).unwrap().len(), 5);
        // Not root's (tests do not run as root).
        #[cfg(unix)]
        if unsafe { libc::geteuid() } != 0 {
            assert_eq!(read_at(&file, true), Err(Problem::Untrusted));
        }
        #[cfg(unix)]
        {
            let link = dir.join("link.env");
            std::os::unix::fs::symlink(&file, &link).unwrap();
            assert_eq!(read_at(&link, false), Err(Problem::Untrusted));
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Staging and production machines get no edge rule, so the baked host does not resolve
    /// there: no spawn gets the route (the person's own sign-in or a team launcher stays in
    /// charge). Where the edge resolves (development), the route is kept whole.
    #[test]
    fn a_route_whose_host_does_not_resolve_is_no_route() {
        let plane = validate(parse(BAKED)).unwrap();
        assert!(reachable(plane.clone(), |_| false).is_empty());
        let asked = std::cell::RefCell::new(Vec::new());
        let kept = reachable(plane.clone(), |h| {
            asked.borrow_mut().push(h.to_owned());
            true
        });
        assert_eq!(kept, plane);
        assert_eq!(*asked.borrow(), ["coderouter.cmux.internal"], "one host, asked once");
        // A file whose OpenAI route names another host needs both to resolve.
        let mut split = plane.clone();
        split.insert("OPENAI_BASE_URL".into(), "https://other.example:8443/v1".into());
        assert!(reachable(split.clone(), |h| h == "coderouter.cmux.internal").is_empty());
        assert_eq!(reachable(split.clone(), |_| true), split);
        assert!(reachable(BTreeMap::new(), |_| true).is_empty());
    }

    /// The reported bug: a daemon env with no route gets the machine's; a value anything else
    /// already set (the daemon's, the login shell's, a profile's) is kept.
    #[test]
    fn a_spawn_gets_the_route_only_where_nothing_else_set_it() {
        let plane = validate(parse(BAKED)).unwrap();
        let mut cmd = std::process::Command::new("true");
        cmd.env_clear();
        cmd.env("OPENAI_BASE_URL", "https://mine.example/v1");
        cmd.env_remove("ANTHROPIC_API_KEY");
        let add: BTreeMap<_, _> =
            missing(&plane, |key| has(&cmd, false, key)).into_iter().collect();
        assert_eq!(add["ANTHROPIC_BASE_URL"], "https://coderouter.cmux.internal");
        assert_eq!(add["ANTHROPIC_API_KEY"], PLACEHOLDER);
        assert_eq!(add["OPENAI_API_KEY"], PLACEHOLDER);
        assert!(!add.contains_key("OPENAI_BASE_URL"), "a set value wins");
        let mut env = BTreeMap::from([("ANTHROPIC_BASE_URL".to_owned(), String::new())]);
        for (k, v) in missing(&plane, |key| env.get(key).is_some_and(|v| !v.is_empty())) {
            env.insert(k, v);
        }
        assert_eq!(
            env["ANTHROPIC_BASE_URL"], "https://coderouter.cmux.internal",
            "an empty value is none"
        );
    }
}
