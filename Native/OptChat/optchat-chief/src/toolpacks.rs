//! Chief tool packs (plans/cmux-next/chief-toolpacks-DESIGN.md): the CLIs,
//! skills and sign-ins every Chief gets, as data (`toolpacks/NAME/pack.toml`
//! + SKILL.md) over this one core, so a new service needs no Rust.
//!
//! The core: a named secret store per pack and Chief home (the macOS login
//! keychain, service `cmux.chief.NAME`, written through `security -i` on
//! stdin, so a token is never an argument; else a 0600 file under
//! `$MUX_HOME/optchat/secrets/`), an OAuth device-code login (a fresh code
//! each time one ends, for the pack's window) and a pasted token, a status
//! check over HTTP, and per-call PATH wrappers (session_dir.rs) that give
//! the secret to the pack's CLI as env vars and to git as a credential.
//!
//! Packs: shipped ones ([`BUILTIN`]) are written to the shared folder
//! `~/.cmux/chief/toolpacks/` at host start; a shared pack wins over a
//! shipped one and a Chief's own (`$MUX_HOME/toolpacks/`) over both. A
//! shipped file carries `# cmux-managed: true`; a copy without it is the
//! user's and is never rewritten.

use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::Deserialize;
use serde_json::{Value, json};

/// The packs cmux ships, as `(name, pack.toml, SKILL.md)`, by name.
pub const BUILTIN: [(&str, &str, &str); 5] = [
    (
        "browser",
        include_str!("../toolpacks/browser/pack.toml"),
        include_str!("../toolpacks/browser/SKILL.md"),
    ),
    (
        "cmux",
        include_str!("../toolpacks/cmux/pack.toml"),
        include_str!("../toolpacks/cmux/SKILL.md"),
    ),
    (
        "gdocs",
        include_str!("../toolpacks/gdocs/pack.toml"),
        include_str!("../toolpacks/gdocs/SKILL.md"),
    ),
    (
        "github",
        include_str!("../toolpacks/github/pack.toml"),
        include_str!("../toolpacks/github/SKILL.md"),
    ),
    (
        "vercel",
        include_str!("../toolpacks/vercel/pack.toml"),
        include_str!("../toolpacks/vercel/SKILL.md"),
    ),
];

/// The scripts shipped packs carry as their CLI (`[tool] script`), as
/// `(pack, file name, text)`: written beside pack.toml, mode 0755.
pub const BUILTIN_SCRIPTS: [(&str, &str, &str); 1] =
    [("gdocs", "gdocs", include_str!("../toolpacks/gdocs/gdocs"))];

/// The line that marks a pack file the host may rewrite.
const MANAGED: &str = "# cmux-managed: true";

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Pack {
    pub name: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub description: String,
    /// Run with the secret injected (`pack check NAME`).
    #[serde(default)]
    pub health: Vec<String>,
    #[serde(default = "yes")]
    pub enabled: bool,
    pub tool: Tool,
    pub auth: Option<Auth>,
    pub check: Option<Check>,
    pub inject: Option<Inject>,
    /// Opt-in: with no login of its own, the Chief uses the person's.
    pub share: Option<Share>,
    /// MCP servers the Chief's turns load while the pack is on.
    #[serde(default)]
    pub mcp: Vec<Mcp>,
    #[serde(skip)]
    pub managed: bool,
    /// The folder it was read from (None: shipped, not on disk).
    #[serde(skip)]
    pub dir: Option<PathBuf>,
}

/// One MCP server of a pack: a stdio `command` or a remote `url`.
#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Mcp {
    pub name: String,
    pub command: Option<String>,
    #[serde(default)]
    pub args: Vec<String>,
    /// Literal values, or `secret:PACK` for a pack's stored secret.
    #[serde(default)]
    pub env: std::collections::BTreeMap<String, String>,
    pub url: Option<String>,
    /// `secret:PACK`: sent as `Authorization: Bearer` to a remote server.
    pub bearer: Option<String>,
    /// The tools a turn may call; empty means all of them.
    #[serde(default)]
    pub tools: Vec<String>,
    #[serde(default = "yes")]
    pub enabled: bool,
}

impl Mcp {
    fn secret_refs(&self) -> impl Iterator<Item = &str> {
        self.env
            .values()
            .chain(self.bearer.iter())
            .filter_map(|v| v.strip_prefix("secret:"))
    }

    /// Runs through `chief pack mcp` (a secret to hand over, tools to keep).
    fn launched(&self) -> bool {
        self.command.is_some() && (self.secret_refs().next().is_some() || !self.tools.is_empty())
    }
}

fn yes() -> bool {
    true
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Tool {
    pub bin: String,
    /// The CLI is this file of the pack's own folder (a script it ships), not
    /// a program on PATH: the turn's `bin/<bin>` runs it.
    pub script: Option<String>,
    pub brew: Option<String>,
    pub apt: Option<String>,
    pub npm: Option<String>,
    pub url: Option<String>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Auth {
    /// `device` and/or `paste`.
    pub methods: Vec<String>,
    #[serde(default = "token_min")]
    pub token_min: usize,
    #[serde(default = "token_max")]
    pub token_max: usize,
    pub login_hint: Option<String>,
    pub revoke_url: Option<String>,
    /// The app's name on the revoke page.
    pub revoke_name: Option<String>,
    pub tokens_url: Option<String>,
    /// The pack's skill (its SKILL.md's name).
    pub skill: Option<String>,
    pub device: Option<Device>,
}

fn token_min() -> usize {
    20
}

fn token_max() -> usize {
    255
}

/// OAuth 2.0 device authorization grant (RFC 8628).
#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Device {
    pub client_id: String,
    pub code_url: String,
    pub token_url: String,
    #[serde(default)]
    pub scopes: String,
    pub verification_uri: String,
    /// A fresh code each time one ends unapproved, this long from the first.
    #[serde(default = "window")]
    pub window_minutes: u64,
}

fn window() -> u64 {
    180
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Check {
    pub url: String,
    pub accept: Option<String>,
    /// A dotted path in the JSON answer (`user.username`).
    pub login_field: String,
    pub scopes_header: Option<String>,
    pub expiry_header: Option<String>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Inject {
    #[serde(default)]
    pub env: Vec<String>,
    pub git_host: Option<String>,
    #[serde(default = "git_user")]
    pub git_user: String,
    /// git asks `<tool.bin> ARGS...` instead (gh: `auth git-credential`).
    #[serde(default)]
    pub git_via_tool: Vec<String>,
}

fn git_user() -> String {
    "x-access-token".into()
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Share {
    pub label: String,
    pub command: Vec<String>,
}

fn word_ok(s: &str, extra: &[u8]) -> bool {
    !s.is_empty()
        && s.as_bytes()[0].is_ascii_alphanumeric()
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || extra.contains(&b))
}

/// A pack from its pack.toml; every field that reaches a shell is checked.
pub fn parse(text: &str) -> Result<Pack, String> {
    let mut p: Pack = toml::from_str(text).map_err(|e| e.to_string())?;
    p.managed = text.lines().any(|l| l.trim() == MANAGED);
    if p.title.is_empty() {
        p.title = p.name.clone();
    }
    let lower = p
        .name
        .bytes()
        .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-');
    if !word_ok(&p.name, b"-") || !lower {
        return Err(format!("name {:?}: [a-z0-9-] only", p.name));
    }
    if !word_ok(&p.tool.bin, b"._-") {
        return Err(format!("tool.bin {:?}: [A-Za-z0-9._-] only", p.tool.bin));
    }
    if let Some(s) = p.tool.script.as_deref().filter(|s| !word_ok(s, b"._-")) {
        return Err(format!(
            "tool.script {s:?}: a file name of the pack's folder"
        ));
    }
    if let Some(i) = &p.inject {
        if let Some(e) = i.env.iter().find(|e| {
            !e.bytes()
                .all(|b| b.is_ascii_uppercase() || b.is_ascii_digit() || b == b'_')
                || e.is_empty()
                || e.as_bytes()[0].is_ascii_digit()
        }) {
            return Err(format!("inject.env {e:?}: [A-Z0-9_] only"));
        }
        if let Some(h) = i.git_host.as_deref().filter(|h| !word_ok(h, b".-")) {
            return Err(format!("inject.git_host {h:?}: a host name only"));
        }
        if let Some(a) = i.git_via_tool.iter().find(|a| !word_ok(a, b"._:-")) {
            return Err(format!("inject.git_via_tool {a:?}: [A-Za-z0-9._:-] only"));
        }
        if !word_ok(&i.git_user, b"._-") {
            return Err(format!("inject.git_user {:?}", i.git_user));
        }
        if p.auth.is_none() {
            return Err("inject needs an [auth] table".into());
        }
    }
    let mut names = std::collections::BTreeSet::new();
    for m in &p.mcp {
        if !word_ok(&m.name, b"_-") || m.name == "optchat" || !names.insert(m.name.clone()) {
            return Err(format!(
                "mcp.name {:?}: [A-Za-z0-9_-], unique, not optchat",
                m.name
            ));
        }
        match (&m.command, &m.url) {
            (Some(_), None) => {}
            (None, Some(u)) if u.starts_with("https://") || u.starts_with("http://127.0.0.1") => {}
            _ => {
                return Err(format!(
                    "mcp {}: one stdio command or one https url",
                    m.name
                ));
            }
        }
        if m.command.is_some() && m.bearer.is_some() {
            return Err(format!("mcp {}: bearer is for a url server", m.name));
        }
        if let Some(r) = m.secret_refs().find(|r| !word_ok(r, b"-")) {
            return Err(format!("mcp {}: secret:{r:?} names no pack", m.name));
        }
        if let Some(k) = m.env.keys().find(|k| !word_ok(k, b"_")) {
            return Err(format!("mcp {}: env {k:?}", m.name));
        }
    }
    Ok(p)
}

/// A shipped pack by name.
pub fn builtin(name: &str) -> Option<Pack> {
    BUILTIN
        .iter()
        .find(|b| b.0 == name)
        .and_then(|b| parse(b.1).ok())
}

/// The shared packs of the Chiefs under `mux_home`'s parent.
pub fn shared_dir(mux_home: &Path) -> PathBuf {
    mux_home.parent().unwrap_or(mux_home).join("toolpacks")
}

/// One Chief's own packs.
pub fn chief_dir(mux_home: &Path) -> PathBuf {
    mux_home.join("toolpacks")
}

/// Writes every shipped pack into `dir` (`<dir>/<name>/pack.toml` and
/// SKILL.md): a new one, or one still marked managed that differs. Answers
/// the names written.
pub fn install_builtin(dir: &Path) -> std::io::Result<Vec<String>> {
    let mut written = Vec::new();
    for (name, toml, skill) in BUILTIN {
        let mut wrote = false;
        let scripts = BUILTIN_SCRIPTS
            .iter()
            .filter(|s| s.0 == name)
            .map(|s| (s.1, s.2));
        for (file, text) in [("pack.toml", toml), ("SKILL.md", skill)]
            .into_iter()
            .chain(scripts)
        {
            let path = dir.join(name).join(file);
            match std::fs::read_to_string(&path) {
                Ok(old) if old == text => continue,
                Ok(old) if !old.contains(MANAGED) && !old.contains("cmux-managed: true") => {
                    continue;
                }
                _ => {}
            }
            std::fs::create_dir_all(dir.join(name))?;
            crate::session_dir::write_if_changed(&path, text.as_bytes())?;
            if file != "pack.toml" && file != "SKILL.md" {
                use std::os::unix::fs::PermissionsExt;
                std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755))?;
            }
            wrote = true;
        }
        if wrote {
            written.push(name.to_owned());
        }
    }
    Ok(written)
}

/// A Chief's switches over the packs' own `enabled` (`pack enable|disable`):
/// `$MUX_HOME/toolpacks.json`, `{"NAME": true|false, "NAME/SERVER": ...}`.
pub fn switches_path(mux_home: &Path) -> PathBuf {
    mux_home.join("toolpacks.json")
}

fn switches(mux_home: &Path) -> serde_json::Map<String, Value> {
    std::fs::read(switches_path(mux_home))
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default()
}

/// Turns a pack (`NAME`) or one of its servers (`NAME/SERVER`) on or off
/// for this Chief.
pub fn set_enabled(mux_home: &Path, key: &str, on: bool) -> Result<(), String> {
    let mut s = switches(mux_home);
    s.insert(key.to_owned(), json!(on));
    std::fs::create_dir_all(mux_home).map_err(|e| e.to_string())?;
    std::fs::write(switches_path(mux_home), format!("{:#}\n", Value::Object(s)))
        .map_err(|e| e.to_string())
}

/// Every pack of a Chief, on or off: shipped, then shared, then its own, by
/// name (a later folder wins), then the Chief's switches; sorted by name.
/// A pack that does not parse is skipped with a line on stderr.
pub fn load_all(mux_home: &Path) -> Vec<Pack> {
    let mut by_name = std::collections::BTreeMap::new();
    for (name, toml, _) in BUILTIN {
        if let Ok(p) = parse(toml) {
            by_name.insert(name.to_owned(), p);
        }
    }
    for dir in [shared_dir(mux_home), chief_dir(mux_home)] {
        let Ok(entries) = std::fs::read_dir(&dir) else {
            continue;
        };
        let mut dirs: Vec<PathBuf> = entries.flatten().map(|e| e.path()).collect();
        dirs.sort();
        for d in dirs {
            let path = d.join("pack.toml");
            let Ok(text) = std::fs::read_to_string(&path) else {
                continue;
            };
            match parse(&text) {
                Ok(mut p) => {
                    p.dir = Some(d);
                    by_name.insert(p.name.clone(), p);
                }
                Err(e) => eprintln!("optchat-chief toolpacks: {}: {e}", path.display()),
            }
        }
    }
    let s = switches(mux_home);
    let mut packs: Vec<Pack> = by_name.into_values().collect();
    for p in &mut packs {
        if let Some(on) = s.get(&p.name).and_then(Value::as_bool) {
            p.enabled = on;
        }
        for m in &mut p.mcp {
            if let Some(on) = s
                .get(&format!("{}/{}", p.name, m.name))
                .and_then(Value::as_bool)
            {
                m.enabled = on;
            }
        }
    }
    packs
}

/// The packs that are on for a Chief.
pub fn load(mux_home: &Path) -> Vec<Pack> {
    load_all(mux_home)
        .into_iter()
        .filter(|p| p.enabled)
        .collect()
}

/// A pack's skills as `(name, folder)`: its own SKILL.md and each
/// `skills/<name>/SKILL.md`. A shipped pack not on disk is written to
/// `$MUX_HOME/optchat/pack-skills/` first.
fn skills_of(mux_home: &Path, pack: &Pack) -> Vec<(String, PathBuf)> {
    let dir = match &pack.dir {
        Some(d) => d.clone(),
        None => {
            let Some((_, _, text)) = BUILTIN.iter().find(|b| b.0 == pack.name) else {
                return Vec::new();
            };
            let d = pack_skills_dir(mux_home).join(&pack.name);
            if std::fs::create_dir_all(&d).is_err()
                || crate::session_dir::write_if_changed(&d.join("SKILL.md"), text.as_bytes())
                    .is_err()
            {
                return Vec::new();
            }
            d
        }
    };
    let mut folders = vec![dir.clone()];
    if let Ok(entries) = std::fs::read_dir(dir.join("skills")) {
        let mut more: Vec<PathBuf> = entries.flatten().map(|e| e.path()).collect();
        more.sort();
        folders.extend(more);
    }
    folders
        .into_iter()
        .filter_map(|f| {
            let text = std::fs::read_to_string(f.join("SKILL.md")).ok()?;
            let (name, _) = crate::skills::front_matter(&text)?;
            word_ok(&name, b"._-").then_some((name, f))
        })
        .collect()
}

fn pack_skills_dir(mux_home: &Path) -> PathBuf {
    mux_home.join("optchat").join("pack-skills")
}

/// Makes the Chief's own skills folder (`$MUX_HOME/skills`, which the
/// prompt names and which wins over the shared one) hold a link to every
/// skill of the packs that are on, and no link to a pack that is off. A
/// real folder of the same name is the user's and wins.
pub fn sync_skills(mux_home: &Path, packs: &[Pack]) {
    let skills = crate::skills::chief_dir(mux_home);
    let want: Vec<(String, PathBuf)> = packs.iter().flat_map(|p| skills_of(mux_home, p)).collect();
    let roots = [
        shared_dir(mux_home),
        chief_dir(mux_home),
        pack_skills_dir(mux_home),
    ];
    let ours = |target: &Path| roots.iter().any(|r| target.starts_with(r));
    if let Ok(entries) = std::fs::read_dir(&skills) {
        for e in entries.flatten() {
            let Ok(target) = std::fs::read_link(e.path()) else {
                continue;
            };
            let name = e.file_name().to_string_lossy().into_owned();
            if ours(&target) && !want.iter().any(|(n, f)| *n == name && *f == target) {
                let _ = std::fs::remove_file(e.path());
            }
        }
    }
    if want.is_empty() {
        return;
    }
    let _ = std::fs::create_dir_all(&skills);
    for (name, folder) in want {
        let link = skills.join(&name);
        if link.symlink_metadata().is_err() {
            let _ = std::os::unix::fs::symlink(&folder, &link);
        }
    }
}

/// The packs' servers in Claude Code's `.mcp.json` shape, by name.
pub fn claude_servers(packs: &[Pack], bin: &Path) -> Vec<(String, Value)> {
    let chief = bin.join("chief").display().to_string();
    let mut out: Vec<(String, Value)> = Vec::new();
    for p in packs {
        for m in p.mcp.iter().filter(|m| m.enabled) {
            if out.iter().any(|(n, _)| *n == m.name) {
                continue;
            }
            let v = if m.launched() {
                json!({"type": "stdio", "command": chief, "args": ["pack", "mcp", p.name, m.name]})
            } else if let Some(c) = &m.command {
                json!({"type": "stdio", "command": c, "args": m.args, "env": m.env})
            } else {
                let mut v = json!({"type": "http", "url": m.url});
                if m.bearer.is_some() {
                    v["headersHelper"] = json!(format!(
                        "{} pack mcp-headers {} {}",
                        crate::session_dir::shell_quote(&chief),
                        p.name,
                        m.name
                    ));
                }
                v
            };
            out.push((m.name.clone(), v));
        }
    }
    out
}

/// The packs' servers as codex `[mcp_servers.NAME]` tables. A remote server
/// with a bearer secret is left out (codex reads it only from its own env).
pub fn codex_servers(packs: &[Pack], bin: &Path) -> toml::Table {
    let chief = bin.join("chief").display().to_string();
    let mut out = toml::Table::new();
    for p in packs {
        for m in p.mcp.iter().filter(|m| m.enabled) {
            if out.contains_key(&m.name) {
                continue;
            }
            let mut t = toml::Table::new();
            if m.launched() {
                t.insert("command".into(), chief.clone().into());
                t.insert(
                    "args".into(),
                    vec!["pack", "mcp", p.name.as_str(), m.name.as_str()].into(),
                );
            } else if let Some(c) = &m.command {
                t.insert("command".into(), c.clone().into());
                t.insert("args".into(), m.args.clone().into());
                let env: toml::Table = m
                    .env
                    .iter()
                    .map(|(k, v)| (k.clone(), v.clone().into()))
                    .collect();
                t.insert("env".into(), env.into());
            } else if m.bearer.is_some() {
                eprintln!(
                    "optchat-chief toolpacks: {}/{}: codex gets no remote server with a secret",
                    p.name, m.name
                );
                continue;
            } else {
                t.insert("url".into(), m.url.clone().unwrap_or_default().into());
            }
            if !m.tools.is_empty() {
                t.insert("enabled_tools".into(), m.tools.clone().into());
            }
            out.insert(m.name.clone(), t.into());
        }
    }
    out
}

fn secret_of(mux_home: &Path, packs: &[Pack], name: &str) -> Result<String, String> {
    let p = packs
        .iter()
        .find(|p| p.name == name)
        .ok_or_else(|| format!("secret:{name}: no such pack is on"))?;
    store(mux_home, p).get().ok_or_else(|| {
        format!(
            "secret:{name}: this Chief has no {} token (chief pack status {name})",
            p.title
        )
    })
}

fn find_server<'a>(packs: &'a [Pack], pack: &str, server: &str) -> Result<&'a Mcp, String> {
    packs
        .iter()
        .find(|p| p.name == pack)
        .and_then(|p| p.mcp.iter().find(|m| m.name == server && m.enabled))
        .ok_or_else(|| format!("no MCP server {pack}/{server} is on"))
}

/// `pack mcp-headers PACK SERVER`: Claude Code's headersHelper answer.
pub fn mcp_headers(mux_home: &Path, pack: &str, server: &str) -> Result<String, String> {
    let packs = load(mux_home);
    let m = find_server(&packs, pack, server)?;
    let r = m
        .bearer
        .as_deref()
        .and_then(|b| b.strip_prefix("secret:"))
        .ok_or("no bearer")?;
    Ok(json!({"Authorization": format!("Bearer {}", secret_of(mux_home, &packs, r)?)}).to_string())
}

/// `pack mcp PACK SERVER`: runs a stdio server with its secrets in its env
/// (never in a file or argv), and keeps only the pack's allowed tools: a
/// `tools/list` answer is filtered, a `tools/call` of another tool refused.
pub fn serve_mcp(mux_home: &Path, pack: &str, server: &str) -> Result<i32, String> {
    use std::io::BufRead;
    let packs = load(mux_home);
    let m = find_server(&packs, pack, server)?.clone();
    let mut cmd = Command::new(m.command.as_deref().ok_or("not a stdio server")?);
    cmd.args(&m.args);
    for (k, v) in &m.env {
        match v.strip_prefix("secret:") {
            Some(r) => cmd.env(k, secret_of(mux_home, &packs, r)?),
            None => cmd.env(k, v),
        };
    }
    if m.tools.is_empty() {
        use std::os::unix::process::CommandExt;
        return Err(format!("{}: {}", m.name, cmd.exec()));
    }
    let mut child = cmd
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .map_err(|e| format!("{}: {e}", m.name))?;
    let out = std::sync::Arc::new(std::sync::Mutex::new(std::io::stdout()));
    let lists = std::sync::Arc::new(std::sync::Mutex::new(Vec::<Value>::new()));
    let mut to_child = child.stdin.take().ok_or("no stdin")?;
    let from_child = child.stdout.take().ok_or("no stdout")?;
    let allowed = m.tools.clone();
    let (out2, lists2) = (out.clone(), lists.clone());
    let reader = std::thread::spawn(move || {
        for line in std::io::stdin().lock().lines() {
            let Ok(line) = line else { break };
            let msg: Value = serde_json::from_str(&line).unwrap_or(Value::Null);
            match msg["method"].as_str() {
                Some("tools/list") => lists2.lock().unwrap().push(msg["id"].clone()),
                Some("tools/call")
                    if !allowed.iter().any(|t| msg["params"]["name"] == json!(t)) =>
                {
                    let e = json!({"jsonrpc": "2.0", "id": msg["id"], "error": {"code": -32601,
                        "message": format!("tool {} is not allowed by its pack", msg["params"]["name"])}});
                    let mut o = out2.lock().unwrap();
                    let _ = writeln!(o, "{e}");
                    let _ = o.flush();
                    continue;
                }
                _ => {}
            }
            if writeln!(to_child, "{line}")
                .and_then(|()| to_child.flush())
                .is_err()
            {
                break;
            }
        }
    });
    for line in std::io::BufReader::new(from_child).lines() {
        let Ok(line) = line else { break };
        let mut msg: Value = serde_json::from_str(&line).unwrap_or(Value::Null);
        let listed = {
            let mut l = lists.lock().unwrap();
            let at = l.iter().position(|id| *id == msg["id"] && !id.is_null());
            at.map(|i| l.remove(i)).is_some()
        };
        let text = if listed && let Some(tools) = msg["result"]["tools"].as_array_mut() {
            tools.retain(|t| m.tools.iter().any(|a| t["name"] == json!(a)));
            msg.to_string()
        } else {
            line
        };
        let mut o = out.lock().unwrap();
        let _ = writeln!(o, "{text}");
        let _ = o.flush();
    }
    drop(reader);
    let status = child.wait().map_err(|e| e.to_string())?;
    Ok(status.code().unwrap_or(1))
}

pub fn status_path(home: &Path, name: &str) -> PathBuf {
    home.join("optchat").join(format!("{name}.json"))
}

pub fn secret_file(home: &Path, name: &str) -> PathBuf {
    home.join("optchat")
        .join("secrets")
        .join(format!("{name}.json"))
}

impl Pack {
    pub fn keychain_service(&self) -> String {
        format!("cmux.chief.{}", self.name)
    }

    /// `[A-Za-z0-9_.-]`, alphanumeric first, within the pack's length: the
    /// only text the keychain command reads on stdin.
    pub fn token_ok(&self, token: &str) -> bool {
        let (min, max) = self
            .auth
            .as_ref()
            .map_or((token_min(), token_max()), |a| (a.token_min, a.token_max));
        (min..=max).contains(&token.len()) && word_ok(token, b"_.-")
    }

    fn login_hint(&self) -> String {
        self.auth
            .as_ref()
            .and_then(|a| a.login_hint.clone())
            .unwrap_or_else(|| format!("chief pack login {}", self.name))
    }
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as u64)
}

/// Where a pack's own secret lives.
pub trait Store {
    fn get(&self) -> Option<String>;
    fn set(&self, token: &str) -> Result<(), String>;
    fn clear(&self) -> Result<(), String>;
}

/// The macOS login keychain.
pub struct Keychain {
    pub account: String,
    pub pack: Pack,
}

impl Store for Keychain {
    fn get(&self) -> Option<String> {
        let out = Command::new("/usr/bin/security")
            .args(["find-generic-password", "-s", &self.pack.keychain_service()])
            .args(["-a", &self.account, "-w"])
            .stderr(Stdio::null())
            .output()
            .ok()?;
        let t = String::from_utf8(out.stdout).ok()?.trim().to_owned();
        (out.status.success() && self.pack.token_ok(&t)).then_some(t)
    }
    fn set(&self, token: &str) -> Result<(), String> {
        if !self.pack.token_ok(token) {
            return Err(format!("not a {} token", self.pack.title));
        }
        let mut child = Command::new("/usr/bin/security")
            .arg("-i")
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| format!("security: {e}"))?;
        let line = format!(
            "add-generic-password -U -s {} -a {} -l \"cmux Chief {}\" -w {token}\n",
            self.pack.keychain_service(),
            self.account,
            self.pack.title.replace(['"', '\\', '\n'], "")
        );
        child
            .stdin
            .take()
            .ok_or("security: no stdin")?
            .write_all(line.as_bytes())
            .map_err(|e| format!("security: {e}"))?;
        let out = child
            .wait_with_output()
            .map_err(|e| format!("security: {e}"))?;
        if out.status.success() && self.get().as_deref() == Some(token) {
            Ok(())
        } else {
            Err("the keychain did not take the token".into())
        }
    }
    fn clear(&self) -> Result<(), String> {
        let _ = Command::new("/usr/bin/security")
            .args([
                "delete-generic-password",
                "-s",
                &self.pack.keychain_service(),
            ])
            .args(["-a", &self.account])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
        Ok(())
    }
}

/// A 0600 file in a 0700 folder under the Chief home (no keychain).
pub struct FileStore {
    pub path: PathBuf,
    pub pack: Pack,
}

impl Store for FileStore {
    fn get(&self) -> Option<String> {
        let v: Value = serde_json::from_slice(&std::fs::read(&self.path).ok()?).ok()?;
        v["token"]
            .as_str()
            .filter(|t| self.pack.token_ok(t))
            .map(str::to_owned)
    }
    fn set(&self, token: &str) -> Result<(), String> {
        if !self.pack.token_ok(token) {
            return Err(format!("not a {} token", self.pack.title));
        }
        use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
        if let Some(dir) = self.path.parent() {
            std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
            let _ = std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700));
        }
        let tmp = self.path.with_extension("tmp");
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&tmp)
            .map_err(|e| e.to_string())?;
        f.write_all(json!({ "token": token }).to_string().as_bytes())
            .map_err(|e| e.to_string())?;
        std::fs::rename(&tmp, &self.path).map_err(|e| e.to_string())
    }
    fn clear(&self) -> Result<(), String> {
        match std::fs::remove_file(&self.path) {
            Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(e.to_string()),
            _ => Ok(()),
        }
    }
}

/// The store of a pack in this Chief home on this machine.
pub fn store(home: &Path, pack: &Pack) -> Box<dyn Store> {
    if cfg!(target_os = "macos") && Path::new("/usr/bin/security").exists() {
        Box::new(Keychain {
            account: crate::paths::home_id(home),
            pack: pack.clone(),
        })
    } else {
        Box::new(FileStore {
            path: secret_file(home, &pack.name),
            pack: pack.clone(),
        })
    }
}

/// An expiry header ("2026-12-01 00:00:00 UTC" or "... +0000") in ms.
pub fn expiry_ms(header: &str) -> Option<u64> {
    let mut parts = header.split_whitespace();
    let (date, time, zone) = (parts.next()?, parts.next()?, parts.next()?);
    let offset = match zone {
        "UTC" => "+00:00".to_owned(),
        z if z.len() == 5 => format!("{}:{}", &z[..3], &z[3..]),
        _ => return None,
    };
    chrono::DateTime::parse_from_rfc3339(&format!("{date}T{time}{offset}"))
        .ok()
        .and_then(|t| u64::try_from(t.timestamp_millis()).ok())
}

/// A scopes header as a sorted list (empty for fine-grained tokens).
pub fn scopes_of(header: &str) -> Vec<String> {
    let mut s: Vec<String> = header
        .split(',')
        .map(|s| s.trim().to_owned())
        .filter(|s| !s.is_empty())
        .collect();
    s.sort();
    s
}

/// `url` as a Markdown link named by its address without the scheme
/// (`[github.com/login/device](https://github.com/login/device)`): a bare or
/// bold URL does not open in every chat (Lawrence 2026-10-23).
pub fn page_link(url: &str) -> String {
    let name = url
        .strip_prefix("https://")
        .or_else(|| url.strip_prefix("http://"))
        .unwrap_or(url);
    format!("[{name}]({url})")
}

/// The message the Chief posts: the code (one tap copies it) and the page
/// alone on its line, as a Markdown link (``page_link``).
pub fn card(pack: &Pack, user_code: &str, uri: &str) -> String {
    format!(
        "Sign in to {} for this Chief: copy the code `{user_code}`, open the page below and approve.\n{}",
        pack.title,
        page_link(uri)
    )
}

fn agent() -> ureq::Agent {
    ureq::AgentBuilder::new()
        .timeout(Duration::from_secs(20))
        .user_agent("cmux-chief")
        .build()
}

/// Who a token is: login, scopes, expiry (the pack's `[check]`).
fn who_is(pack: &Pack, token: &str) -> Result<Value, String> {
    let Some(c) = &pack.check else {
        return Ok(json!({"login": null, "scopes": [], "expires_at": null}));
    };
    let mut req = agent()
        .get(&c.url)
        .set("authorization", &format!("Bearer {token}"));
    if let Some(a) = &c.accept {
        req = req.set("accept", a);
    }
    match req.call() {
        Ok(r) => {
            let header =
                |h: &Option<String>| h.as_deref().and_then(|h| r.header(h)).map(str::to_owned);
            let scopes = scopes_of(&header(&c.scopes_header).unwrap_or_default());
            let expires = header(&c.expiry_header).as_deref().and_then(expiry_ms);
            let body: Value = r.into_json().map_err(|e| e.to_string())?;
            let login = c.login_field.split('.').fold(&body, |v, k| &v[k]);
            Ok(json!({"login": login, "scopes": scopes, "expires_at": expires}))
        }
        Err(ureq::Error::Status(code, _)) => {
            Err(format!("{} refused the token (HTTP {code})", pack.title))
        }
        Err(e) => Err(format!("{} did not answer: {e}", pack.title)),
    }
}

fn read_status(home: &Path, pack: &Pack) -> Value {
    std::fs::read(status_path(home, &pack.name))
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_else(|| json!({}))
}

fn write_status(home: &Path, pack: &Pack, v: &Value) -> Result<(), String> {
    let p = status_path(home, &pack.name);
    if let Some(d) = p.parent() {
        std::fs::create_dir_all(d).map_err(|e| e.to_string())?;
    }
    std::fs::write(&p, format!("{v:#}\n")).map_err(|e| e.to_string())
}

fn keep(home: &Path, pack: &Pack, kind: &str, token: &str) -> Result<Value, String> {
    let who = who_is(pack, token)?;
    store(home, pack).set(token)?;
    let now = now_ms();
    let v = json!({"kind": kind, "login": who["login"], "scopes": who["scopes"],
        "expires_at": who["expires_at"], "set_at": now, "checked_at": now});
    write_status(home, pack, &v)?;
    Ok(status(home, pack))
}

/// The person's own login on this machine (`[share]`), when signed in.
fn shared_login(pack: &Pack) -> Option<Value> {
    let (program, args) = pack.share.as_ref()?.command.split_first()?;
    let out = Command::new(program)
        .args(args)
        .stderr(Stdio::null())
        .output()
        .ok()?;
    let t = String::from_utf8(out.stdout).ok()?.trim().to_owned();
    if !out.status.success() || t.is_empty() {
        return None;
    }
    who_is(pack, &t).ok()
}

/// The status: the Chief's own login, else the shared one (kind `mac`).
pub fn status(home: &Path, pack: &Pack) -> Value {
    let mut s = read_status(home, pack);
    let own = pack.auth.is_some() && store(home, pack).get().is_some();
    if own && s.get("kind").is_some() {
        s["signed_in"] = json!(true);
        s["own"] = json!(true);
    } else {
        let pending = s.get("pending").cloned();
        s = match shared_login(pack) {
            Some(w) => json!({"signed_in": true, "own": false, "kind": "mac",
                "login": w["login"], "scopes": w["scopes"], "expires_at": w["expires_at"]}),
            None => json!({"signed_in": false, "own": false}),
        };
        if let Some(p) = pending {
            s["pending"] = p;
        }
    }
    if s["pending"]["expires_at"]
        .as_u64()
        .is_some_and(|t| t <= now_ms())
    {
        s.as_object_mut().map(|o| o.remove("pending"));
    }
    s
}

fn device_of(pack: &Pack) -> Result<&Device, String> {
    pack.auth
        .as_ref()
        .filter(|a| a.methods.iter().any(|m| m == "device"))
        .and_then(|a| a.device.as_ref())
        .ok_or_else(|| {
            format!(
                "{} has no device sign-in; paste a token: chief pack paste {} -",
                pack.title, pack.name
            )
        })
}

/// One device-flow poll: Ok(Some(token)) once approved, Ok(None) while
/// pending (with the next interval), Err when it ended.
fn poll(pack: &Pack, device_code: &str, interval: &mut u64) -> Result<Option<String>, String> {
    let d = device_of(pack)?;
    let r = agent()
        .post(&d.token_url)
        .set("accept", "application/json")
        .send_form(&[
            ("client_id", d.client_id.as_str()),
            ("device_code", device_code),
            ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
        ]);
    let body: Value = match r {
        Ok(r) => r.into_json().map_err(|e| e.to_string())?,
        Err(ureq::Error::Status(_, r)) => r.into_json().unwrap_or(Value::Null),
        Err(_) => return Ok(None),
    };
    if let Some(t) = body["access_token"].as_str() {
        return Ok(Some(t.to_owned()));
    }
    match body["error"].as_str() {
        Some("authorization_pending") | None => Ok(None),
        Some("slow_down") => {
            *interval += 5;
            Ok(None)
        }
        Some("access_denied") => Err(format!("the sign-in was denied on {}", pack.title)),
        Some(e) => Err(format!("{} ended the sign-in ({e})", pack.title)),
    }
}

/// One device code.
struct DeviceCode {
    device: String,
    user_code: String,
    uri: String,
    expires_at: u64,
    interval: u64,
}

fn request_code(pack: &Pack) -> Result<DeviceCode, String> {
    let d = device_of(pack)?;
    let r: Value = agent()
        .post(&d.code_url)
        .set("accept", "application/json")
        .send_form(&[
            ("client_id", d.client_id.as_str()),
            ("scope", d.scopes.as_str()),
        ])
        .map_err(|e| format!("{} did not start a device sign-in: {e}", pack.title))?
        .into_json()
        .map_err(|e| e.to_string())?;
    let (Some(device), Some(code)) = (r["device_code"].as_str(), r["user_code"].as_str()) else {
        return Err(format!("{}'s answer has no device code", pack.title));
    };
    Ok(DeviceCode {
        device: device.to_owned(),
        user_code: code.to_owned(),
        uri: r["verification_uri"]
            .as_str()
            .unwrap_or(&d.verification_uri)
            .to_owned(),
        expires_at: now_ms() + r["expires_in"].as_u64().unwrap_or(900) * 1000,
        interval: r["interval"].as_u64().unwrap_or(5),
    })
}

/// What the poller does next with its current code.
#[derive(Debug, PartialEq, Eq)]
pub enum Next {
    Poll,
    /// The code ended: ask for a new one.
    Renew,
    /// The window ended with no approval.
    GiveUp,
}

pub fn next_step(now: u64, code_expires: u64, window_end: u64) -> Next {
    if now < code_expires {
        Next::Poll
    } else if now < window_end {
        Next::Renew
    } else {
        Next::GiveUp
    }
}

/// The device window of a pack, in ms.
pub fn window_ms(pack: &Pack) -> u64 {
    device_of(pack).map_or(window(), |d| d.window_minutes) * 60 * 1000
}

fn window_words(pack: &Pack) -> String {
    let m = window_ms(pack) / 60_000;
    if m.is_multiple_of(60) {
        format!("{} hours", m / 60)
    } else {
        format!("{m} minutes")
    }
}

fn write_pending(
    home: &Path,
    pack: &Pack,
    c: &DeviceCode,
    started_at: u64,
    renewals: u64,
    pid: u32,
) -> Result<(), String> {
    let mut s = read_status(home, pack);
    s["pending"] = json!({"user_code": c.user_code, "verification_uri": c.uri, "expires_at": c.expires_at,
        "started_at": started_at, "until": started_at + window_ms(pack), "renewals": renewals, "pid": pid});
    if let Some(o) = s.as_object_mut() {
        o.remove("last_error");
    }
    write_status(home, pack, &s)
}

/// `login`: starts the device flow, leaves a detached poller that outlives
/// the turn (it reads the device code on stdin and asks for a new code each
/// time one ends, for the pack's window) and returns the card.
fn login(home: &Path, pack: &Pack) -> Result<Value, String> {
    let c = request_code(pack)?;
    let started_at = now_ms();
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let _ = std::fs::create_dir_all(home.join("optchat"));
    let log = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(
            home.join("optchat")
                .join(format!("{}-login.log", pack.name)),
        )
        .map_err(|e| e.to_string())?;
    use std::os::unix::process::CommandExt;
    let mut child = Command::new(exe)
        .args(["pack", "poll", &pack.name, "--mux-home"])
        .arg(home)
        .args(["--interval", &c.interval.to_string()])
        .args(["--expires", &c.expires_at.to_string()])
        .args(["--started", &started_at.to_string()])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(log)
        // Its own process group: the turn's end does not stop it.
        .process_group(0)
        .spawn()
        .map_err(|e| format!("starting the poller: {e}"))?;
    child
        .stdin
        .take()
        .ok_or("poller: no stdin")?
        .write_all(c.device.as_bytes())
        .map_err(|e| e.to_string())?;
    write_pending(home, pack, &c, started_at, 0, child.id())?;
    let mut out = status(home, pack);
    out["card"] = json!(card(pack, &c.user_code, &c.uri));
    // When to wake (the Chief's `sleep` tool) to post the next code.
    out["wake_in"] = json!((c.expires_at.saturating_sub(now_ms()) / 1000 + 5).max(30));
    Ok(out)
}

/// The detached poller (`pack poll NAME`): the first device code on stdin.
fn poll_loop(
    home: &Path,
    pack: &Pack,
    mut interval: u64,
    mut expires: u64,
    started: u64,
) -> Result<Value, String> {
    let mut device = String::new();
    std::io::stdin()
        .read_to_string(&mut device)
        .map_err(|e| e.to_string())?;
    let mut device = device.trim().to_owned();
    let mut renewals = 0;
    let end = |error: &str| {
        let mut s = read_status(home, pack);
        if let Some(o) = s.as_object_mut() {
            o.remove("pending");
            o.insert("last_error".into(), json!(error));
        }
        let _ = write_status(home, pack, &s);
    };
    loop {
        match next_step(now_ms(), expires, started + window_ms(pack)) {
            Next::GiveUp => {
                end(&format!(
                    "no one approved the {} sign-in in {}; run `{}` again",
                    pack.title,
                    window_words(pack),
                    pack.login_hint()
                ));
                return Err("expired".into());
            }
            Next::Renew => match request_code(pack) {
                Ok(c) => {
                    renewals += 1;
                    device = c.device.clone();
                    expires = c.expires_at;
                    interval = c.interval;
                    write_pending(home, pack, &c, started, renewals, std::process::id())?;
                }
                Err(_) => std::thread::sleep(Duration::from_secs(30)),
            },
            Next::Poll => {
                std::thread::sleep(Duration::from_secs(interval.max(1)));
                match poll(pack, &device, &mut interval) {
                    Ok(Some(token)) => {
                        return keep(home, pack, "device", &token).inspect_err(|e| end(e));
                    }
                    Ok(None) => {}
                    Err(e) if e.contains("expired_token") => expires = 0,
                    Err(e) => {
                        end(&e);
                        return Err(e);
                    }
                }
            }
        }
    }
}

fn fallback_words(pack: &Pack) -> String {
    match &pack.share {
        Some(s) => format!("the Chief uses {} login again", s.label),
        None => format!("the Chief has no {} login", pack.title),
    }
}

fn logout(home: &Path, pack: &Pack) -> Result<Value, String> {
    let was = read_status(home, pack);
    store(home, pack).clear()?;
    let _ = std::fs::remove_file(status_path(home, &pack.name));
    let mut s = status(home, pack);
    let auth = pack.auth.as_ref();
    let fall = fallback_words(pack);
    s["note"] = json!(match (was["kind"].as_str(), auth) {
        (
            Some("device"),
            Some(Auth {
                revoke_url: Some(url),
                revoke_name,
                ..
            }),
        ) => format!(
            "Forgotten here; {fall}. The token still works until you revoke it at {}{}.",
            page_link(url),
            revoke_name
                .as_deref()
                .map_or(String::new(), |n| format!(" (\"{n}\")"))
        ),
        (
            Some("pat"),
            Some(Auth {
                tokens_url: Some(url),
                ..
            }),
        ) => {
            format!(
                "Forgotten here; {fall}. Delete the token at {} if nothing else uses it.",
                page_link(url)
            )
        }
        (Some(_), _) => format!("Forgotten here; {fall}."),
        (None, _) => match &pack.share {
            Some(sh) => format!("The Chief uses {} login.", sh.label),
            None => format!("The Chief has no {} login.", pack.title),
        },
    });
    Ok(s)
}

fn read_token(pack: &Pack, source: Option<&str>) -> Result<String, String> {
    let mut text = String::new();
    match source {
        None | Some("-") => {
            std::io::stdin()
                .read_to_string(&mut text)
                .map_err(|e| e.to_string())?;
        }
        Some(file) => text = std::fs::read_to_string(file).map_err(|e| format!("{file}: {e}"))?,
    }
    let t = text.trim().to_owned();
    if pack.token_ok(&t) {
        Ok(t)
    } else {
        Err(format!("that is not one {} token", pack.title))
    }
}

/// One line for people (the default output; `--json` prints the object).
pub fn describe(pack: &Pack, s: &Value) -> String {
    let mut line = if s["signed_in"] == json!(true) {
        let scopes = s["scopes"].as_array().map_or(String::new(), |a| {
            a.iter()
                .filter_map(Value::as_str)
                .collect::<Vec<_>>()
                .join(" ")
        });
        let exp = s["expires_at"].as_u64().map_or(String::new(), |t| {
            chrono::DateTime::from_timestamp_millis(t as i64).map_or(String::new(), |d| {
                format!(", expires {}", d.format("%Y-%m-%d"))
            })
        });
        let whose = if s["own"] == json!(true) {
            ", this Chief's own".to_owned()
        } else {
            format!(
                ", {}",
                pack.share.as_ref().map_or("shared", |sh| sh.label.as_str())
            )
        };
        let scopes = if !scopes.is_empty() {
            format!("; {scopes}")
        } else if pack
            .check
            .as_ref()
            .is_some_and(|c| c.scopes_header.is_some())
        {
            "; fine-grained".to_owned()
        } else {
            String::new()
        };
        format!(
            "signed in as {} ({}{whose}{scopes}{exp})",
            s["login"].as_str().unwrap_or("?"),
            s["kind"].as_str().unwrap_or("?"),
        )
    } else if pack.auth.is_none() {
        format!("{}: no sign-in needed", pack.title)
    } else {
        format!("not signed in to {} ({})", pack.title, pack.login_hint())
    };
    if let Some(p) = s.get("pending").filter(|p| p.is_object()) {
        line.push_str(&format!(
            "\nwaiting for approval: code {} at {}",
            p["user_code"].as_str().unwrap_or("?"),
            p["verification_uri"].as_str().unwrap_or("?")
        ));
    }
    if let Some(e) = s["last_error"].as_str() {
        line.push_str(&format!("\nlast sign-in: {e}"));
    }
    if let Some(c) = s["card"].as_str() {
        let skill = pack
            .auth
            .as_ref()
            .and_then(|a| a.skill.as_deref())
            .map_or(String::new(), |k| format!("; skill {k}"));
        line = format!(
            "{c}\n\n(post the two lines above as your reply; the poller keeps going after your turn and makes a new code when this one ends, for {}. Then call sleep({}, \"{} code ended: {}, post the new code\") to come back with the next one{skill})\n{line}",
            window_words(pack),
            s["wake_in"].as_u64().unwrap_or(905),
            pack.title,
            pack.login_hint().replace(" login", " status"),
        );
    }
    if let Some(n) = s["note"].as_str() {
        line.push_str(&format!("\n{n}"));
    }
    line
}

/// `pack check NAME`: the health command with the secret injected.
fn check(home: &Path, pack: &Pack) -> Result<Value, String> {
    let Some((program, args)) = pack.health.split_first() else {
        return Ok(json!({"pack": pack.name, "ok": true, "note": "no health command"}));
    };
    let mut cmd = Command::new(program);
    cmd.args(args).stdin(Stdio::null());
    if let (Some(i), Some(t)) = (
        &pack.inject,
        pack.auth.as_ref().and_then(|_| store(home, pack).get()),
    ) {
        for e in &i.env {
            cmd.env(e, &t);
        }
    }
    match cmd.output() {
        Ok(o) => Ok(
            json!({"pack": pack.name, "ok": o.status.success(), "code": o.status.code(),
            "out": String::from_utf8_lossy(&o.stdout).chars().take(2000).collect::<String>(),
            "err": String::from_utf8_lossy(&o.stderr).chars().take(2000).collect::<String>()}),
        ),
        Err(e) => Ok(
            json!({"pack": pack.name, "ok": false, "err": format!("{program}: {e}"), "install": install_hint(pack)}),
        ),
    }
}

/// The install command for this machine, as argv.
fn install_cmd(pack: &Pack) -> Option<Vec<String>> {
    let t = &pack.tool;
    let on_path = |p: &str| {
        Command::new("sh")
            .args(["-c", &format!("command -v {p}")])
            .stdout(Stdio::null())
            .status()
            .is_ok_and(|s| s.success())
    };
    let ok = |s: &String| word_ok(s, b"@/._-");
    if let Some(b) = t.brew.as_ref().filter(|b| ok(b) && on_path("brew")) {
        return Some(vec!["brew".into(), "install".into(), b.clone()]);
    }
    if let Some(n) = t.npm.as_ref().filter(|n| ok(n) && on_path("npm")) {
        return Some(vec!["npm".into(), "install".into(), "-g".into(), n.clone()]);
    }
    if let Some(a) = t.apt.as_ref().filter(|a| ok(a) && on_path("apt-get")) {
        return Some(vec![
            "sudo".into(),
            "apt-get".into(),
            "install".into(),
            "-y".into(),
            a.clone(),
        ]);
    }
    None
}

fn install_hint(pack: &Pack) -> Value {
    match install_cmd(pack) {
        Some(c) => json!(c.join(" ")),
        None => json!(pack.tool.url),
    }
}

pub const USAGE: &str = "optchat-chief pack list | enable|disable NAME[/SERVER] | mcp PACK SERVER | status NAME | login NAME | wait NAME [SECONDS] | paste NAME FILE|- | share NAME | logout NAME | token NAME | check NAME | install NAME [--json] [--mux-home DIR]";

/// `optchat-chief pack VERB NAME ...` (`words[0]` is `pack`).
pub fn run(flags: &crate::cli::Flags, home: &Path, as_json: bool) -> Result<String, String> {
    let verb = flags.words.get(1).map_or("list", String::as_str);
    let packs = load(home);
    if verb == "list" {
        let all = load_all(home);
        let skills =
            |p: &Pack| -> Vec<String> { skills_of(home, p).into_iter().map(|(n, _)| n).collect() };
        if as_json {
            let rows: Vec<Value> = all
                .iter()
                .map(|p| json!({"name": p.name, "title": p.title, "description": p.description, "enabled": p.enabled,
                    "tool": p.tool.bin, "auth": p.auth.as_ref().map(|a| a.methods.clone()), "managed": p.managed,
                    "skills": skills(p),
                    "mcp": p.mcp.iter().map(|m| json!({"name": m.name, "enabled": m.enabled,
                        "url": m.url, "command": m.command, "tools": m.tools})).collect::<Vec<_>>()}))
                .collect();
            return Ok(Value::from(rows).to_string());
        }
        return Ok(all
            .iter()
            .map(|p| {
                let mcp: Vec<String> = p
                    .mcp
                    .iter()
                    .map(|m| format!("{}{}", m.name, if m.enabled { "" } else { " (off)" }))
                    .collect();
                format!(
                    "{:<3} {:<10} {:<8} {}{}{}",
                    if p.enabled { "on" } else { "off" },
                    p.name,
                    p.tool.bin,
                    p.description,
                    if p.enabled {
                        format!("\n      skills: {}", skills(p).join(", "))
                    } else {
                        String::new()
                    },
                    if mcp.is_empty() {
                        String::new()
                    } else {
                        format!("\n      mcp: {}", mcp.join(", "))
                    }
                )
            })
            .collect::<Vec<_>>()
            .join("\n"));
    }
    if verb == "enable" || verb == "disable" {
        let key = flags.words.get(2).ok_or(USAGE)?;
        let (pack, server) = key
            .split_once('/')
            .map_or((key.as_str(), None), |(p, s)| (p, Some(s)));
        let all = load_all(home);
        let p = all
            .iter()
            .find(|p| p.name == pack)
            .ok_or_else(|| format!("no pack {pack:?} (chief pack list)"))?;
        if let Some(s) = server.filter(|s| !p.mcp.iter().any(|m| m.name == *s)) {
            return Err(format!("{pack} has no MCP server {s:?}"));
        }
        set_enabled(home, key, verb == "enable")?;
        return Ok(format!(
            "{key}: {}d for this Chief; its next session has it{}",
            verb,
            if verb == "enable" { "" } else { " no more" }
        ));
    }
    let name = flags.words.get(2).ok_or(USAGE)?;
    let pack = packs
        .iter()
        .find(|p| &p.name == name)
        .ok_or_else(|| format!("no pack {name:?} (chief pack list)"))?;
    let needs_auth = || {
        pack.auth
            .as_ref()
            .map(|_| ())
            .ok_or_else(|| format!("{} has no sign-in", pack.title))
    };
    let s = match verb {
        "status" => status(home, pack),
        "login" => {
            needs_auth()?;
            login(home, pack)?
        }
        "wait" => {
            let limit = flags
                .words
                .get(3)
                .and_then(|w| w.parse().ok())
                .unwrap_or(600u64);
            let end = now_ms() + limit * 1000;
            loop {
                let s = status(home, pack);
                if s["own"] == json!(true) || s.get("pending").is_none() || now_ms() >= end {
                    break s;
                }
                std::thread::sleep(Duration::from_secs(3));
            }
        }
        "paste" => {
            needs_auth()?;
            keep(
                home,
                pack,
                "pat",
                &read_token(pack, flags.words.get(3).map(String::as_str))?,
            )?
        }
        "share" => {
            // The person's own login: no copy of the Chief's own.
            store(home, pack).clear()?;
            let _ = std::fs::remove_file(status_path(home, &pack.name));
            status(home, pack)
        }
        "logout" => logout(home, pack)?,
        // A wrapper's call: the Chief's own token, or nothing (exit 1).
        "token" => {
            needs_auth()?;
            return store(home, pack)
                .get()
                .ok_or_else(|| format!("no {} token of this Chief's own", pack.title));
        }
        "check" => {
            let c = check(home, pack)?;
            return Ok(if as_json {
                c.to_string()
            } else {
                format!(
                    "{}: {}\n{}{}",
                    pack.name,
                    if c["ok"] == json!(true) {
                        "ok"
                    } else {
                        "failed"
                    },
                    c["out"].as_str().unwrap_or(""),
                    c["err"].as_str().unwrap_or("")
                )
                .trim_end()
                .to_owned()
            });
        }
        "install" => {
            let argv = install_cmd(pack).ok_or_else(|| {
                format!(
                    "no installer for {} here; see {}",
                    pack.tool.bin,
                    pack.tool.url.as_deref().unwrap_or("its site")
                )
            })?;
            let st = Command::new(&argv[0])
                .args(&argv[1..])
                .status()
                .map_err(|e| e.to_string())?;
            json!({"pack": pack.name, "ran": argv.join(" "), "ok": st.success()})
        }
        "poll" => {
            let num = |k: &str| flags.value(k).and_then(|v| v.parse::<u64>().ok());
            let started = num("started").unwrap_or_else(now_ms);
            poll_loop(
                home,
                pack,
                num("interval").unwrap_or(5),
                num("expires").unwrap_or(started + 900_000),
                started,
            )?
        }
        _ => return Err(USAGE.into()),
    };
    Ok(if as_json {
        s.to_string()
    } else {
        describe(pack, &s)
    })
}

/// The shell lines that drop the script's own folder from PATH.
const DROP_SELF: &str = r#"self_dir=$(cd "$(dirname "$0")" && pwd -P)
PATH=$(printf '%s' "$PATH" | tr ':' '
' | while IFS= read -r d; do
  [ -n "$d" ] && [ "$(cd "$d" 2>/dev/null && pwd -P)" != "$self_dir" ] && printf '%s:' "$d"
done)
PATH=${PATH%:}
export PATH
"#;

/// The files a turn's launcher folder gets for the packs, as
/// `(file name, text)`: a wrapper per CLI that takes a secret, and a git
/// credential helper per git host. A later pack with the same CLI is left out.
pub fn wrappers(packs: &[Pack]) -> Vec<(String, String)> {
    let mut out: Vec<(String, String)> = Vec::new();
    for p in packs {
        let Some(i) = &p.inject else { continue };
        let bin = &p.tool.bin;
        // A pack that ships its CLI gets its wrapper from script_wrappers.
        if p.tool.script.is_none() && !i.env.is_empty() && !out.iter().any(|(n, _)| n == bin) {
            let first = &i.env[0];
            let mut text = format!(
                "#!/bin/sh\n# optchat-chief: {bin} with this Chief's own {} login when it has one\n# (tool pack {}, toolpacks.rs; `chief pack status {}`), else as it is.\n{DROP_SELF}",
                p.title, p.name, p.name
            );
            text.push_str(&format!(
                "if [ -z \"${{{first}:-}}\" ] && t=$(\"$self_dir/chief\" pack token {} 2>/dev/null) && [ -n \"$t\" ]; then\n",
                p.name
            ));
            for e in &i.env {
                text.push_str(&format!("  {e}=$t\n  export {e}\n"));
            }
            text.push_str(&format!(
                "fi\nif ! command -v {bin} >/dev/null 2>&1; then\n  echo \"{bin}: not found on PATH (after the Chief's own bin)\" >&2\n  exit 127\nfi\nexec {bin} \"$@\"\n"
            ));
            out.push((bin.clone(), text));
        }
        if let Some(host) = &i.git_host {
            let mut text = format!(
                "#!/bin/sh\n# optchat-chief: git credentials for https://{host} (tool pack {}, toolpacks.rs).\nself_dir=$(cd \"$(dirname \"$0\")\" && pwd -P)\n",
                p.name
            );
            if i.git_via_tool.is_empty() {
                text.push_str(&format!(
                    "[ \"$1\" = get ] || exit 0\nt=$(\"$self_dir/chief\" pack token {} 2>/dev/null) || exit 0\n[ -n \"$t\" ] || exit 0\nprintf 'username={}\\npassword=%s\\n' \"$t\"\n",
                    p.name, i.git_user
                ));
            } else {
                text.push_str(&format!(
                    "exec \"$self_dir/{bin}\" {} \"$@\"\n",
                    i.git_via_tool.join(" ")
                ));
            }
            out.push((format!("git-credential-chief-{}", p.name), text));
        }
    }
    out
}

/// The turn's `bin/<tool.bin>` for each pack that ships its CLI as a script
/// (`[tool] script`), as `(file name, text)`: it puts the Chief's own token
/// in the pack's env vars when it has one (`chief pack token`, per call),
/// then runs the script from the pack's folder. A shipped pack not on disk
/// yet gets its script under `$MUX_HOME/optchat/pack-skills/NAME/` first.
pub fn script_wrappers(mux_home: &Path, packs: &[Pack]) -> Vec<(String, String)> {
    let mut out: Vec<(String, String)> = Vec::new();
    for p in packs {
        let Some(script) = &p.tool.script else {
            continue;
        };
        if out.iter().any(|(n, _)| *n == p.tool.bin) {
            continue;
        }
        let path = match &p.dir {
            Some(d) => d.join(script),
            None => {
                let Some((_, _, text)) = BUILTIN_SCRIPTS
                    .iter()
                    .find(|b| b.0 == p.name && b.1 == script)
                else {
                    continue;
                };
                let d = pack_skills_dir(mux_home).join(&p.name);
                let path = d.join(script);
                let written = std::fs::create_dir_all(&d)
                    .and_then(|()| crate::session_dir::write_if_changed(&path, text.as_bytes()))
                    .and_then(|()| {
                        use std::os::unix::fs::PermissionsExt;
                        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755))
                    });
                if let Err(e) = written {
                    eprintln!("optchat-chief toolpacks: {}: {e}", path.display());
                    continue;
                }
                path
            }
        };
        let quoted = format!("'{}'", path.display().to_string().replace('\'', "'\\''"));
        let mut text = format!(
            "#!/bin/sh\n# optchat-chief: {} (tool pack {}, toolpacks.rs; `chief pack status {}`), the pack's own script.\nself_dir=$(cd \"$(dirname \"$0\")\" && pwd -P)\n",
            p.tool.bin, p.name, p.name
        );
        if let Some(i) = p.inject.as_ref().filter(|i| !i.env.is_empty()) {
            let first = &i.env[0];
            text.push_str(&format!(
                "if [ -z \"${{{first}:-}}\" ] && t=$(\"$self_dir/chief\" pack token {} 2>/dev/null) && [ -n \"$t\" ]; then\n",
                p.name
            ));
            for e in &i.env {
                text.push_str(&format!("  {e}=$t\n  export {e}\n"));
            }
            text.push_str("fi\n");
        }
        text.push_str(&format!("exec {quoted} \"$@\"\n"));
        out.push((p.tool.bin.clone(), text));
    }
    out
}

/// The turn env that makes git ask the packs' helpers (GIT_CONFIG_* is
/// git's command-line config: each host's helper list is reset first, so
/// the person's own helper does not answer before it).
pub fn git_env(packs: &[Pack], bin: &Path) -> Vec<(String, String)> {
    let mut pairs = Vec::new();
    for p in packs {
        if let Some(host) = p.inject.as_ref().and_then(|i| i.git_host.as_ref()) {
            let key = format!("credential.https://{host}.helper");
            let helper = bin
                .join(format!("git-credential-chief-{}", p.name))
                .display()
                .to_string();
            pairs.push((key.clone(), String::new()));
            pairs.push((key, helper));
        }
    }
    if pairs.is_empty() {
        return Vec::new();
    }
    let mut env = vec![("GIT_CONFIG_COUNT".to_owned(), pairs.len().to_string())];
    for (n, (k, v)) in pairs.into_iter().enumerate() {
        env.push((format!("GIT_CONFIG_KEY_{n}"), k));
        env.push((format!("GIT_CONFIG_VALUE_{n}"), v));
    }
    env
}

#[cfg(test)]
mod tests {
    use super::*;

    fn gh() -> Pack {
        builtin("github").unwrap()
    }

    #[test]
    fn reads_expiry_and_scope_headers() {
        assert_eq!(
            expiry_ms("2026-12-01 00:00:00 UTC"),
            Some(1_796_083_200_000)
        );
        assert_eq!(
            expiry_ms("2026-12-01 01:00:00 +0100"),
            Some(1_796_083_200_000)
        );
        assert_eq!(expiry_ms("soon"), None);
        assert_eq!(
            scopes_of("workflow, repo,gist , read:org"),
            ["gist", "read:org", "repo", "workflow"]
        );
        assert!(scopes_of("").is_empty());
    }

    #[test]
    fn keeps_a_fresh_code_until_the_window_ends() {
        let start = 1_000_000;
        let window = start + window_ms(&gh());
        assert_eq!(
            next_step(start + 60_000, start + 900_000, window),
            Next::Poll
        );
        assert_eq!(
            next_step(start + 900_000, start + 900_000, window),
            Next::Renew
        );
        assert_eq!(next_step(window - 1, start + 900_000, window), Next::Renew);
        assert_eq!(next_step(window, window + 900_000, window), Next::Poll);
        assert_eq!(next_step(window, start + 900_000, window), Next::GiveUp);
        assert_eq!(window_ms(&gh()), 10_800_000);
        assert_eq!(window_words(&gh()), "3 hours");
    }

    #[test]
    fn github_tokens_as_before() {
        let p = gh();
        assert!(p.token_ok("gho_0123456789abcdefABCDEF0123"));
        assert!(p.token_ok("github_pat_11ABCDEFG0123456789_abcdefghijklmnop"));
        assert!(!p.token_ok("gho_short"));
        assert!(!p.token_ok("gho_0123456789abcdef -w evil"));
        assert!(!p.token_ok("gho_0123456789abcdef\"\nadd-generic-password"));
    }

    #[test]
    fn githubs_wrapper_and_git_env_are_a607s() {
        let w = wrappers(&[gh()]);
        let shim = &w.iter().find(|(n, _)| n == "gh").unwrap().1;
        assert!(shim.contains(
            "if [ -z \"${GH_TOKEN:-}\" ] && t=$(\"$self_dir/chief\" pack token github 2>/dev/null)"
        ));
        assert!(shim.contains("exec gh \"$@\""));
        let env = git_env(&[gh()], Path::new("/h/optchat/bin"));
        assert_eq!(env[0], ("GIT_CONFIG_COUNT".into(), "2".into()));
        assert_eq!(env[1].1, "credential.https://github.com.helper");
        assert_eq!(env[2], ("GIT_CONFIG_VALUE_0".into(), String::new()));
        assert_eq!(env[4].1, "/h/optchat/bin/git-credential-chief-github");
        assert!(git_env(&[builtin("cmux").unwrap()], Path::new("/b")).is_empty());
    }

    #[test]
    fn card_has_the_code_and_the_page_as_a_markdown_link_on_its_own_line() {
        let c = card(&gh(), "ABCD-1234", "https://github.com/login/device");
        assert!(c.contains("`ABCD-1234`"));
        // A Markdown link with a short name (Lawrence 2026-10-23: a bare or bold URL did not open).
        assert!(c.ends_with("\n[github.com/login/device](https://github.com/login/device)"));
        assert_eq!(page_link("http://x.dev/a"), "[x.dev/a](http://x.dev/a)");
    }

    #[test]
    fn the_card_hint_names_the_window_and_skill() {
        let s = json!({"signed_in": false, "card": card(&gh(), "ABCD-1234", "https://github.com/login/device"), "wake_in": 905});
        let d = describe(&gh(), &s);
        assert!(d.contains("for 3 hours"), "{d}");
        assert!(
            d.contains("sleep(905, \"GitHub code ended: chief github status, post the new code\")"),
            "{d}"
        );
        assert!(d.contains("; skill github-signin)"), "{d}");
        let none = json!({"signed_in": false, "pending": {"user_code": "ABCD-1234", "verification_uri": "https://github.com/login/device"}});
        assert!(describe(&gh(), &none).contains("waiting for approval: code ABCD-1234"));
    }
}
