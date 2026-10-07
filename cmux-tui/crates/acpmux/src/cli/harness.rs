//! `cmux harness …` (also `acpmux harness …`): add, list, check and reload
//! harness profile files (BRING-YOUR-OWN-HARNESS H2). The commands work
//! without a running daemon; `add` and `reload` tell a running one to read
//! the files again.
//!
//! `doctor` starts the harness in a fresh private temp folder, runs the ACP
//! handshake (`initialize`, `session/new`) and one prompt, and prints each
//! step with an exact fix. An id the catalog lacks may be a folder profile
//! (`--folder DIR` or the current folder, or their nearest parent): an
//! enabled one starts with its folder as the working folder, because its
//! relative arguments and PATH entries (and the bytes `enable` hashed) are
//! relative to that folder and a session may use it only inside it; one that
//! is not enabled fails with the exact next step. It never prints an env value: every resolved env
//! value is masked in all output, harness stderr included.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::{Result, anyhow, bail};
use serde::Serialize;
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};

use crate::cli::command::{HarnessCmd, SecretCmd};
use crate::config::folder_profiles;
use crate::config::profiles::{self, ProfileSources, Severity};
use crate::config::{Config, HarnessKind, HarnessProfile, ProfileSource};

/// Example profiles shipped with acpmux, by id (`harness add --example`).
pub const EXAMPLES: &[(&str, &str)] = &[
    ("claude", include_str!("../../harnesses/claude.toml")),
    ("codex", include_str!("../../harnesses/codex.toml")),
    ("opencode", include_str!("../../harnesses/opencode.toml")),
    ("pi", include_str!("../../harnesses/pi.toml")),
    ("gemini", include_str!("../../harnesses/gemini.toml")),
    ("aider", include_str!("../../harnesses/aider.toml")),
];

/// The guide an agent follows to integrate a harness (`cmux harness guide`).
pub const GUIDE: &str = include_str!("../../skills/integrate-harness/SKILL.md");

/// The prompt doctor sends.
pub const DOCTOR_PROMPT: &str = "Reply with the single word OK.";

/// An example by id or by its longer name (`claude-code`, `gemini-cli`).
pub fn example(name: &str) -> Option<&'static str> {
    let id = match name {
        "claude-code" => "claude",
        "gemini-cli" => "gemini",
        "aider-terminal" | "terminal" => "aider",
        other => other,
    };
    EXAMPLES.iter().find(|(e, _)| *e == id).map(|(_, text)| *text)
}

pub async fn run(cmd: HarnessCmd, json_out: bool) -> Result<()> {
    match cmd {
        HarnessCmd::List { folder: None } => list(json_out),
        HarnessCmd::List { folder: Some(dir) } => super::harness_folder::list(&dir, json_out),
        HarnessCmd::Enable { id, folder, yes } => {
            super::harness_folder::enable_cmd(&id, &folder, yes, json_out)
        }
        HarnessCmd::Disable { id, folder } => super::harness_folder::disable_cmd(&id, &folder),
        HarnessCmd::Run { tab: true, .. } => {
            bail!("--tab opens a cmux tab: run `cmux harness run ID --tab`")
        }
        HarnessCmd::Run { id, cwd, model, tab: false } => {
            super::harness_run::run_cmd(&id, cwd, model)
        }
        HarnessCmd::Secret(SecretCmd::Set { id, key }) => {
            super::harness_secret::set_cmd(&id, &key).await
        }
        HarnessCmd::Add { id, command, protocol, example, force } => {
            let sources = ProfileSources::current();
            let req = AddRequest { id, command, protocol, example, force };
            let added = add(&req, &sources)?;
            let reloaded = reload_daemon().await;
            if json_out {
                println!(
                    "{}",
                    json!({"id": added.id, "path": added.path, "diagnostics": added.diagnostics,
                        "daemonReloaded": reloaded})
                );
            } else {
                println!("wrote {}", added.path.display());
                for d in &added.diagnostics {
                    print_diagnostic(d);
                }
                println!("next: edit the file, then run `cmux harness doctor {}`", added.id);
            }
            Ok(())
        }
        HarnessCmd::Doctor { id, folder, no_prompt, timeout } => {
            let cfg = Config::load()?;
            let here = std::env::current_dir()?;
            let opts = DoctorOptions {
                folder: Some(folder.map(|f| here.join(f)).unwrap_or(here)),
                prompt: !no_prompt,
                timeout: Duration::from_secs(timeout.max(5)),
                lookup_env: Box::new(|var| std::env::var(var).ok()),
                lookup_keychain: Box::new(profiles::keychain_lookup),
            };
            let report = doctor(&cfg, &id, &opts).await;
            if json_out {
                println!("{}", serde_json::to_string_pretty(&report)?);
            } else {
                print!("{}", report.text());
            }
            let failed = report.steps.iter().filter(|s| s.status == StepStatus::Fail).count();
            if failed > 0 {
                bail!("doctor: {failed} step(s) failed for {id}");
            }
            Ok(())
        }
        HarnessCmd::Guide => {
            print!("{GUIDE}");
            Ok(())
        }
        HarnessCmd::Reload => {
            if reload_daemon().await {
                println!("the daemon read the harness profiles again");
            } else {
                println!("no daemon is running; it reads the profiles when it starts");
            }
            Ok(())
        }
    }
}

/// Ask a running daemon to reload its catalog; false when none runs.
pub(crate) async fn reload_daemon() -> bool {
    match crate::daemon::connect(false).await {
        Ok(client) => {
            client.request(crate::rpc::method::MUX_RELOAD_CONFIG, json!({})).await.is_ok()
        }
        Err(_) => false,
    }
}

// ------------------------------------------------------------------ list

fn list(json_out: bool) -> Result<()> {
    let cfg = Config::load()?;
    let rows = list_rows(&cfg);
    if json_out {
        println!(
            "{}",
            serde_json::to_string_pretty(
                &json!({"harnesses": rows, "diagnostics": cfg.profile_diagnostics})
            )?
        );
        return Ok(());
    }
    for r in &rows {
        println!("{:<16} {:<12} {:<14} {}", r.id, r.kind, r.source, r.name);
        if let Some(path) = &r.path {
            println!("{:<16} {path}", "");
        }
    }
    for d in &cfg.profile_diagnostics {
        print_diagnostic(d);
    }
    if rows.is_empty() {
        println!("no harnesses. Add one with `cmux harness add`.");
    }
    Ok(())
}

#[derive(Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ListRow {
    pub id: String,
    pub name: String,
    pub kind: String,
    /// managed, user-file, cmux-json, acpmux-config or discovered.
    pub source: String,
    pub path: Option<String>,
}

pub fn list_rows(cfg: &Config) -> Vec<ListRow> {
    cfg.harnesses
        .iter()
        .map(|(id, p)| {
            let meta = cfg.profile_meta.get(id);
            let source = match meta.map(|m| m.source) {
                Some(ProfileSource::Managed) => "managed",
                Some(ProfileSource::UserFile) => "user-file",
                Some(ProfileSource::CmuxJson) => "cmux-json",
                None if cfg.discovered.contains(id) => "discovered",
                None => "acpmux-config",
            };
            ListRow {
                id: id.clone(),
                name: meta
                    .and_then(|m| m.display_name.clone())
                    .unwrap_or_else(|| p.description.clone().unwrap_or_default()),
                kind: kind_name(p.kind).into(),
                source: source.into(),
                path: meta.map(|m| m.source_path.clone()),
            }
        })
        .collect()
}

fn kind_name(kind: HarnessKind) -> &'static str {
    match kind {
        HarnessKind::Acp => "acp",
        HarnessKind::ClaudeStdio => "claude-stdio",
        HarnessKind::Terminal => "terminal",
    }
}

fn print_diagnostic(d: &profiles::Diagnostic) {
    let level = match d.severity {
        Severity::Error => "error",
        Severity::Warning => "warning",
    };
    println!("{level}: {}: {}", d.path, d.message);
    if let Some(fix) = &d.fix {
        println!("  fix: {fix}");
    }
}

// ------------------------------------------------------------------- add

pub struct AddRequest {
    pub id: Option<String>,
    pub command: Option<String>,
    pub protocol: String,
    pub example: Option<String>,
    pub force: bool,
}

pub struct Added {
    pub id: String,
    pub path: PathBuf,
    pub diagnostics: Vec<profiles::Diagnostic>,
}

/// Write a new profile file into the user's harness folder and check it.
pub fn add(req: &AddRequest, sources: &ProfileSources) -> Result<Added> {
    let dir = sources
        .user_dir
        .clone()
        .ok_or_else(|| anyhow!("no harness folder: set HOME or XDG_CONFIG_HOME"))?;
    if !matches!(req.protocol.as_str(), "acp" | "terminal") {
        bail!("--protocol must be acp or terminal, got {:?}", req.protocol);
    }
    let example = match &req.example {
        Some(name) => Some(example(name).ok_or_else(|| {
            let names: Vec<&str> = EXAMPLES.iter().map(|(id, _)| *id).collect();
            anyhow!("no example {name:?}; examples: {}", names.join(", "))
        })?),
        None => None,
    };
    let command_stem = req.command.as_deref().map(|c| {
        Path::new(c).file_name().map(|f| f.to_string_lossy().into_owned()).unwrap_or_default()
    });
    let id = req
        .id
        .clone()
        .or_else(|| req.example.as_deref().and_then(example_id))
        .or(command_stem.map(|s| s.to_ascii_lowercase()))
        .ok_or_else(|| anyhow!("give an id: `cmux harness add <id> --command <program>`"))?;
    if !profiles::valid_id(&id) {
        bail!("id {id:?} must be 1-40 lowercase letters, digits or '-'");
    }
    let text = match example {
        Some(text) => with_id(text, &id),
        None => {
            let command = req.command.clone().ok_or_else(|| {
                anyhow!(
                    "give the program: `cmux harness add {id} --command <program>`, or --example"
                )
            })?;
            scaffold(&id, &command, &req.protocol)
        }
    };
    let path = dir.join(format!("{id}.toml"));
    if path.exists() && !req.force {
        bail!(
            "{} exists; edit it and run `cmux harness doctor {id}`, or pass --force",
            path.display()
        );
    }
    {
        use std::os::unix::fs::DirBuilderExt;
        std::fs::DirBuilder::new().recursive(true).mode(0o700).create(&dir)?;
    }
    crate::config::write_atomic(&path, text.as_bytes())?;
    let diagnostics =
        match profiles::parse_profile_toml(&text, &path, Some(&id), ProfileSource::UserFile) {
            Ok((_, _, _, warnings)) => warnings,
            Err(errors) => errors,
        };
    Ok(Added { id, path, diagnostics })
}

fn example_id(name: &str) -> Option<String> {
    let text = example(name)?;
    text.lines()
        .find_map(|l| l.strip_prefix("id = \""))
        .and_then(|rest| rest.strip_suffix('"'))
        .map(str::to_owned)
}

/// An example's text with its `id = "…"` line set to `id`.
fn with_id(text: &str, id: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for line in text.lines() {
        if line.starts_with("id = \"") {
            out.push_str(&format!("id = \"{id}\""));
        } else {
            out.push_str(line);
        }
        out.push('\n');
    }
    out
}

/// A commented profile for `command`.
pub fn scaffold(id: &str, command: &str, protocol: &str) -> String {
    let mut name: Vec<char> = id.replace('-', " ").chars().collect();
    if let Some(first) = name.first_mut() {
        *first = first.to_ascii_uppercase();
    }
    let name: String = name.into_iter().collect();
    let command = command.replace('\\', "\\\\").replace('"', "\\\"");
    format!(
        r#"# cmux harness profile. Guide: docs/add-your-harness.md
# Check it with: cmux harness doctor {id}
schema = 1
id = "{id}"
name = "{name}"
# icon = "{id}.svg"       # a file next to this one, or: claude, openai, opencode, pi, gemini, terminal
protocol = "{protocol}"   # "acp" (Agent Client Protocol over stdio) or "terminal" (a CLI/TUI without ACP)
command = "{command}"     # a program on your PATH, or an absolute path
args = []                 # for example ["acp"]; "${{model}}" becomes the chosen model

[env]
# PLAIN = "value"
# API_KEY = {{ keychain = "cmux-harness/{id}/API_KEY" }}   # never write a secret in this file
# SOME_DIR = {{ env = "SOME_DIR" }}                         # copied from your login shell

# [defaults]
# model = "model-id"
# effort = "medium"
# policy = "ask"          # ask, approve-reads, approve-edits, approve-all, deny-all

# [models]
# list = [{{ id = "model-id", name = "Model Name", short_name = "Short" }}]

# [auth]
# login = "{command} login"
# docs = "https://example.com/setup"
"#
    )
}

// ---------------------------------------------------------------- doctor

pub struct DoctorOptions {
    /// Where to look for a folder profile (it and its parents) when the
    /// catalog has no harness of that id. None: catalog harnesses only.
    pub folder: Option<PathBuf>,
    /// Send one prompt after the handshake.
    pub prompt: bool,
    /// Time limit for each step that waits on the harness.
    pub timeout: Duration,
    pub lookup_env: Box<dyn Fn(&str) -> Option<String> + Send + Sync>,
    pub lookup_keychain: Box<dyn Fn(&str, Option<&str>) -> Result<String, String> + Send + Sync>,
}

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum StepStatus {
    Pass,
    Warn,
    Fail,
    Skip,
}

#[derive(Debug, Clone, Serialize)]
pub struct Step {
    pub step: &'static str,
    pub status: StepStatus,
    pub detail: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fix: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct DoctorReport {
    pub id: String,
    pub ok: bool,
    pub steps: Vec<Step>,
    /// The harness's reply to the doctor prompt, masked.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reply: Option<String>,
}

impl DoctorReport {
    pub fn text(&self) -> String {
        let mut out = format!("cmux harness doctor {}\n", self.id);
        for s in &self.steps {
            let tag = match s.status {
                StepStatus::Pass => "PASS",
                StepStatus::Warn => "WARN",
                StepStatus::Fail => "FAIL",
                StepStatus::Skip => "SKIP",
            };
            out.push_str(&format!("{tag}  {:<10} {}\n", s.step, s.detail));
            if let Some(fix) = &s.fix {
                out.push_str(&format!("      fix: {fix}\n"));
            }
        }
        if let Some(reply) = &self.reply {
            out.push_str(&format!("reply: {reply}\n"));
        }
        out.push_str(if self.ok { "ready\n" } else { "not ready\n" });
        out
    }
}

struct Report {
    id: String,
    steps: Vec<Step>,
    reply: Option<String>,
    masks: Vec<String>,
}

impl Report {
    fn mask(&self, text: &str) -> String {
        let mut out = text.to_owned();
        for m in &self.masks {
            out = out.replace(m.as_str(), "***");
        }
        out
    }
    fn push(&mut self, step: &'static str, status: StepStatus, detail: &str, fix: Option<String>) {
        let detail = self.mask(detail);
        let fix = fix.map(|f| self.mask(&f));
        self.steps.push(Step { step, status, detail, fix });
    }
    fn done(self) -> DoctorReport {
        let ok = self.steps.iter().all(|s| s.status != StepStatus::Fail);
        let reply = self.reply.as_deref().map(|r| self.mask(r));
        DoctorReport { id: self.id, ok, steps: self.steps, reply }
    }
}

/// Check one harness end to end. Never returns an env value in any field.
pub async fn doctor(cfg: &Config, id: &str, opts: &DoctorOptions) -> DoctorReport {
    let mut r = Report { id: id.to_owned(), steps: Vec::new(), reply: None, masks: Vec::new() };
    // 1. The profile.
    let problems: Vec<&profiles::Diagnostic> =
        cfg.profile_diagnostics.iter().filter(|d| d.id.as_deref() == Some(id)).collect();
    let catalog_error = problems.iter().find(|d| d.severity == Severity::Error);
    // An id the catalog lacks may be a folder profile (H4): only an enabled
    // one runs, inside its folder.
    let folder_target = match (cfg.harnesses.get(id), catalog_error) {
        (None, None) => opts
            .folder
            .as_deref()
            .and_then(|start| super::harness_folder::doctor_target(cfg, id, start)),
        _ => None,
    };
    let (profile, workdir, source) = match (cfg.harnesses.get(id), &folder_target) {
        (Some(profile), _) => {
            let source = cfg
                .profile_meta
                .get(id)
                .map(|m| m.source_path.clone())
                .unwrap_or_else(|| "acpmux config or PATH discovery".into());
            (profile, None, source)
        }
        (None, Some(Ok(target))) => (
            &target.profile,
            Some(target.folder.as_path()),
            format!("{} (folder profile, enabled)", target.path),
        ),
        (None, Some(Err((detail, fix)))) => {
            r.push("profile", StepStatus::Fail, detail, fix.clone());
            return r.done();
        }
        (None, None) => {
            match catalog_error {
                Some(d) => r.push(
                    "profile",
                    StepStatus::Fail,
                    &format!("{}: {}", d.path, d.message),
                    d.fix.clone(),
                ),
                None => r.push(
                    "profile",
                    StepStatus::Fail,
                    &format!("no harness {id:?}"),
                    Some(format!("create it: cmux harness add {id} --command <program>")),
                ),
            }
            return r.done();
        }
    };
    r.push(
        "profile",
        StepStatus::Pass,
        &format!("{} harness from {source}", kind_name(profile.kind)),
        None,
    );
    for d in problems {
        r.push("profile", StepStatus::Warn, &d.message, d.fix.clone());
    }
    // 2. The program.
    let program = profile.argv.first().cloned().unwrap_or_default();
    match folder_profiles::resolve_program(profile, workdir) {
        Some(path) => r.push("command", StepStatus::Pass, &path.to_string_lossy(), None),
        None => {
            r.push(
                "command",
                StepStatus::Fail,
                &format!("`{program}` is not on PATH"),
                Some(install_hint(cfg, id, &program)),
            );
            return r.done();
        }
    }
    // 3. Env references. Every value goes into the masks before anything prints.
    let mut env = profile.env.clone();
    let kinds: Vec<String> = env
        .iter()
        .map(|(k, v)| {
            let kind = if v.contains("${keychain:") {
                "keychain"
            } else if v.contains("${env:") {
                "login env"
            } else {
                "plain"
            };
            format!("{k} ({kind})")
        })
        .collect();
    let resolved = profiles::resolve_env_refs(&mut env, &*opts.lookup_env, &*opts.lookup_keychain);
    r.masks = env.values().filter(|v| v.len() >= 6).cloned().collect();
    r.masks.sort_by_key(|m| std::cmp::Reverse(m.len()));
    match resolved {
        Ok(()) if kinds.is_empty() => r.push("env", StepStatus::Pass, "no env", None),
        Ok(()) => r.push("env", StepStatus::Pass, &kinds.join(", "), None),
        Err(e) => {
            let key = e.split(':').next().unwrap_or("").trim_start_matches("env ").to_owned();
            r.push(
                "env",
                StepStatus::Fail,
                &e,
                Some(format!(
                    "cmux harness secret set {id} {key}  (or export it in your login shell)"
                )),
            );
            return r.done();
        }
    }
    // 4. The login check, when the profile has one.
    let meta = cfg.profile_meta.get(id);
    if let Some(check) =
        meta.and_then(|m| m.auth.as_ref()).map(|a| a.check.clone()).filter(|c| !c.is_empty())
    {
        match run_short(&check, &env, Duration::from_secs(30)).await {
            Ok(_) => r.push("auth", StepStatus::Pass, &check.join(" "), None),
            Err(e) => {
                let fix = meta.and_then(|m| m.auth.as_ref()).and_then(|a| a.login.clone());
                r.push("auth", StepStatus::Fail, &e, fix.map(|l| format!("log in: {l}")));
                return r.done();
            }
        }
    }
    match profile.kind {
        HarnessKind::Acp => acp_steps(&mut r, cfg, id, profile, env, opts, workdir).await,
        HarnessKind::Terminal | HarnessKind::ClaudeStdio => {
            let argv = vec![program.clone(), "--version".to_owned()];
            match run_short(&argv, &env, Duration::from_secs(20)).await {
                Ok(out) => r.push(
                    "launch",
                    StepStatus::Pass,
                    out.lines().next().unwrap_or("started"),
                    None,
                ),
                Err(e) => r.push(
                    "launch",
                    StepStatus::Warn,
                    &format!("`{program} --version`: {e}"),
                    Some("some programs have no --version; start it once by hand".into()),
                ),
            }
            let note = if profile.kind == HarnessKind::Terminal {
                format!("terminal harness: no ACP steps; open it with `cmux harness run {id}`")
            } else {
                format!("acpmux's own Claude Code adapter: try `cmux acp new -m {id} \"hi\"`")
            };
            r.push("acp", StepStatus::Skip, &note, None);
        }
    }
    r.done()
}

fn install_hint(cfg: &Config, id: &str, program: &str) -> String {
    let path = cfg.profile_meta.get(id).map(|m| m.source_path.clone());
    let docs = cfg.profile_meta.get(id).and_then(|m| m.auth.as_ref()).and_then(|a| a.docs.clone());
    let mut hint = format!("install `{program}`");
    if let Some(docs) = docs {
        hint.push_str(&format!(" ({docs})"));
    }
    match path {
        Some(p) => hint.push_str(&format!(", or set command to its absolute path in {p}")),
        None => hint.push_str(", or set command to its absolute path"),
    }
    hint
}

/// Run a short command with the profile env; Ok(stdout) on exit 0.
async fn run_short(
    argv: &[String],
    env: &BTreeMap<String, String>,
    limit: Duration,
) -> Result<String, String> {
    let (program, args) = argv.split_first().ok_or("empty command")?;
    let mut cmd = tokio::process::Command::new(program);
    cmd.args(args)
        .envs(env.iter())
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);
    let out = tokio::time::timeout(limit, cmd.output())
        .await
        .map_err(|_| format!("did not finish in {} s", limit.as_secs()))?
        .map_err(|e| e.to_string())?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).trim().to_owned())
    } else {
        let err = String::from_utf8_lossy(&out.stderr);
        Err(format!("{}: {}", out.status, err.lines().last().unwrap_or("").trim()))
    }
}

/// The ACP steps: spawn in `workdir` (a folder profile's folder) or a temp
/// folder, initialize, session/new, prompt.
async fn acp_steps(
    r: &mut Report,
    cfg: &Config,
    id: &str,
    profile: &HarnessProfile,
    env: BTreeMap<String, String>,
    opts: &DoctorOptions,
    workdir: Option<&Path>,
) {
    let temp;
    let folder: &Path = match workdir {
        Some(dir) => dir,
        None => match TempFolder::new(id) {
            Ok(f) => {
                temp = f;
                &temp.path
            }
            Err(e) => {
                r.push("launch", StepStatus::Fail, &format!("temp folder: {e}"), None);
                return;
            }
        },
    };
    let home = dirs::home_dir().unwrap_or_default();
    let model = profile.model.clone().unwrap_or_default();
    let mut spawn = profile.clone();
    spawn.env = env;
    for v in spawn.env.values_mut() {
        *v = crate::hub::expand_env_value(v, folder, &home, &model);
    }
    for a in spawn.argv.iter_mut() {
        *a = crate::hub::expand_env_value(a, folder, &home, &model);
    }
    let mut cmd = match crate::agent::harness_command(id, &spawn, folder, None, None) {
        Ok(cmd) => cmd,
        Err(e) => {
            r.push("launch", StepStatus::Fail, &e.to_string(), None);
            return;
        }
    };
    let mut child = match cmd.spawn() {
        Ok(child) => child,
        Err(e) => {
            r.push(
                "launch",
                StepStatus::Fail,
                &e.to_string(),
                Some(install_hint(cfg, id, &spawn.argv[0])),
            );
            return;
        }
    };
    let pid = child.id();
    let (Some(stdin), Some(stdout), Some(stderr)) =
        (child.stdin.take(), child.stdout.take(), child.stderr.take())
    else {
        r.push("launch", StepStatus::Fail, "no stdio pipes", None);
        return;
    };
    let stderr_tail = std::sync::Arc::new(std::sync::Mutex::new(Vec::<u8>::new()));
    let tail = stderr_tail.clone();
    let mut drain = tokio::spawn(async move {
        let mut stderr = stderr;
        let mut buf = [0u8; 4096];
        while let Ok(n) = stderr.read(&mut buf).await {
            if n == 0 {
                break;
            }
            if let Ok(mut t) = tail.lock() {
                t.extend_from_slice(&buf[..n]);
                let len = t.len();
                if len > 64 * 1024 {
                    t.drain(..len - 64 * 1024);
                }
            }
        }
    });
    r.push(
        "launch",
        StepStatus::Pass,
        &format!("pid {} in {}", pid.unwrap_or(0), folder.display()),
        None,
    );
    let mut wire = Wire {
        stdin,
        lines: BufReader::new(stdout).lines(),
        next: 1,
        reply: String::new(),
        noise: 0,
    };
    let outcome = handshake(r, &mut wire, folder, opts).await;
    // Stop the harness and everything it started (its own process group),
    // then read the rest of its stderr: the pipe closes when it exits.
    if let Some(pid) = pid {
        unsafe {
            libc::killpg(pid as libc::pid_t, libc::SIGKILL);
        }
    }
    let _ = tokio::time::timeout(Duration::from_secs(5), child.wait()).await;
    if tokio::time::timeout(Duration::from_secs(2), &mut drain).await.is_err() {
        drain.abort();
    }
    if !outcome {
        let text = stderr_tail
            .lock()
            .map(|t| String::from_utf8_lossy(&t).into_owned())
            .unwrap_or_default();
        let lines: Vec<&str> = text.lines().collect();
        let last = lines[lines.len().saturating_sub(15)..].join("\n");
        if !last.trim().is_empty() {
            r.push("stderr", StepStatus::Warn, &format!("last harness output:\n{last}"), None);
        }
    }
    if wire.noise > 0 {
        r.push(
            "stdout",
            StepStatus::Warn,
            &format!("{} line(s) on stdout were not JSON-RPC", wire.noise),
            Some(
                "an ACP agent may write only JSON-RPC messages to stdout; send logs to stderr"
                    .into(),
            ),
        );
    }
    if !wire.reply.trim().is_empty() {
        r.reply = Some(wire.reply.trim().to_owned());
    }
}

/// initialize, session/new and the prompt; false at the first failure.
async fn handshake(r: &mut Report, wire: &mut Wire, folder: &Path, opts: &DoctorOptions) -> bool {
    let init = json!({
        "protocolVersion": 1,
        "clientCapabilities": {"fs": {"readTextFile": false, "writeTextFile": false}, "terminal": false},
        "clientInfo": {"name": "cmux harness doctor", "version": env!("CARGO_PKG_VERSION")},
    });
    let result = match wire.call("initialize", init, opts.timeout).await {
        Ok(v) => v,
        Err(e) => {
            r.push(
                "initialize",
                StepStatus::Fail,
                &e,
                Some("the command must speak ACP on stdin/stdout; check args (many agents need an `acp` argument or flag)".into()),
            );
            return false;
        }
    };
    let version = result.get("protocolVersion").cloned().unwrap_or(Value::Null);
    let agent = result
        .pointer("/agentInfo/name")
        .and_then(Value::as_str)
        .map(|n| format!(", agent {n}"))
        .unwrap_or_default();
    if version == json!(1) {
        r.push("initialize", StepStatus::Pass, &format!("ACP protocol 1{agent}"), None);
    } else {
        r.push(
            "initialize",
            StepStatus::Warn,
            &format!("protocolVersion {version}{agent}; cmux speaks ACP protocol 1"),
            None,
        );
    }
    let new = json!({"cwd": folder.to_string_lossy(), "mcpServers": []});
    let session = match wire.call("session/new", new, opts.timeout).await {
        Ok(v) => v,
        Err(e) => {
            let auth = e.contains("auth") || e.contains("-32000") || e.contains("login");
            r.push(
                "session",
                StepStatus::Fail,
                &e,
                Some(if auth {
                    "the harness needs a login: run its login command once, then doctor again"
                        .into()
                } else {
                    "session/new failed; see the harness output below".into()
                }),
            );
            return false;
        }
    };
    let Some(session_id) = session.get("sessionId").and_then(Value::as_str).map(str::to_owned)
    else {
        r.push("session", StepStatus::Fail, "session/new returned no sessionId", None);
        return false;
    };
    r.push("session", StepStatus::Pass, &format!("session {session_id}"), None);
    if !opts.prompt {
        r.push("prompt", StepStatus::Skip, "--no-prompt", None);
        return true;
    }
    let prompt =
        json!({"sessionId": session_id, "prompt": [{"type": "text", "text": DOCTOR_PROMPT}]});
    match wire.call("session/prompt", prompt, opts.timeout).await {
        Ok(v) => {
            let stop = v.get("stopReason").and_then(Value::as_str).unwrap_or("?").to_owned();
            if wire.reply.trim().is_empty() {
                r.push(
                    "prompt",
                    StepStatus::Warn,
                    &format!("turn ended ({stop}) with no reply text"),
                    Some(
                        "check the model and its login; the agent sent no agent_message_chunk"
                            .into(),
                    ),
                );
            } else {
                r.push("prompt", StepStatus::Pass, &format!("turn ended ({stop})"), None);
            }
            true
        }
        Err(e) => {
            r.push(
                "prompt",
                StepStatus::Fail,
                &e,
                Some("check the model, its login and quota".into()),
            );
            false
        }
    }
}

struct Wire {
    stdin: tokio::process::ChildStdin,
    lines: tokio::io::Lines<BufReader<tokio::process::ChildStdout>>,
    next: i64,
    reply: String,
    noise: usize,
}

impl Wire {
    async fn send(&mut self, msg: Value) -> Result<(), String> {
        let mut line = msg.to_string();
        line.push('\n');
        self.stdin
            .write_all(line.as_bytes())
            .await
            .map_err(|e| format!("write to the harness: {e}"))?;
        self.stdin.flush().await.map_err(|e| format!("write to the harness: {e}"))
    }

    /// One request; answers the harness's own requests (permission asks are
    /// cancelled, anything else is refused) and collects reply text.
    async fn call(
        &mut self,
        method: &str,
        params: Value,
        limit: Duration,
    ) -> Result<Value, String> {
        let id = self.next;
        self.next += 1;
        self.send(json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params})).await?;
        let deadline = tokio::time::Instant::now() + limit;
        loop {
            let line = match tokio::time::timeout_at(deadline, self.lines.next_line()).await {
                Err(_) => return Err(format!("no answer to {method} in {} s", limit.as_secs())),
                Ok(Err(e)) => return Err(format!("read from the harness: {e}")),
                Ok(Ok(None)) => {
                    return Err(format!("the harness exited before it answered {method}"));
                }
                Ok(Ok(Some(line))) => line,
            };
            if line.trim().is_empty() {
                continue;
            }
            let Ok(msg) = serde_json::from_str::<Value>(line.trim()) else {
                self.noise += 1;
                continue;
            };
            let incoming = msg.get("method").and_then(Value::as_str).map(str::to_owned);
            match (msg.get("id").cloned(), incoming.as_deref()) {
                (Some(rid), Some("session/request_permission")) => {
                    let answer = json!({"outcome": {"outcome": "cancelled"}});
                    self.send(json!({"jsonrpc": "2.0", "id": rid, "result": answer})).await?;
                }
                (Some(rid), Some(_)) => {
                    let error = json!({"code": -32601, "message": "cmux harness doctor does not serve this method"});
                    self.send(json!({"jsonrpc": "2.0", "id": rid, "error": error})).await?;
                }
                (None, Some("session/update")) => {
                    let update = msg.pointer("/params/update");
                    let kind = update.and_then(|u| u.get("sessionUpdate")).and_then(Value::as_str);
                    if kind == Some("agent_message_chunk")
                        && let Some(text) =
                            update.and_then(|u| u.pointer("/content/text")).and_then(Value::as_str)
                    {
                        self.reply.push_str(text);
                    }
                }
                (Some(rid), None) if rid == json!(id) => {
                    if let Some(e) = msg.get("error") {
                        let code = e.get("code").and_then(Value::as_i64).unwrap_or(0);
                        let message = e.get("message").and_then(Value::as_str).unwrap_or("error");
                        return Err(format!("{method} failed ({code}): {message}"));
                    }
                    return Ok(msg.get("result").cloned().unwrap_or(Value::Null));
                }
                _ => {}
            }
        }
    }
}

/// A private temp folder, removed on drop.
struct TempFolder {
    path: PathBuf,
}

impl TempFolder {
    fn new(id: &str) -> std::io::Result<Self> {
        use std::os::unix::fs::DirBuilderExt;
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.subsec_nanos())
            .unwrap_or(0);
        let path = std::env::temp_dir()
            .join(format!("cmux-harness-doctor-{id}-{}-{nanos}", std::process::id()));
        std::fs::DirBuilder::new().mode(0o700).create(&path)?;
        // One folder key for the trust record and the agent: /tmp vs /private/tmp.
        let path = std::fs::canonicalize(&path).unwrap_or(path);
        Ok(Self { path })
    }
}

impl Drop for TempFolder {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.path);
    }
}

#[cfg(test)]
#[path = "harness_tests.rs"]
mod tests;
