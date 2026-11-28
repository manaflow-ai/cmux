//! Whether a Codex launch already has a server of the person's own named `cmux`, and which one:
//! one rule for both ways cmux gives Codex its server, the `codex` terminal shim (cmux-tui
//! `codex_wrapper.rs`) and Codex agent chats (acpmux `agent_tools`, through cmux-codex-acp's
//! thread config).
//!
//! Codex itself answers it: `codex <the person's config arguments> mcp get cmux --json`, run in
//! the launch folder with the Codex child's environment ([`resolve`]). Its answer is the entry
//! Codex loads for that launch, as Codex merges the user config, the project files it trusts,
//! the `--profile` file and `-c`, so trust, profiles and layer order are Codex's own (decided
//! 2026-11-15, after modelling them in cmux drifted from Codex 0.169 three times). The answer:
//!
//! - a stdio entry, with its exact `command` and `args`: a launch that gives no `cmux` of its own
//!   sends it back whole with the env keys (`mcp_servers.cmux.{command,args,env.KEY}`), so it is
//!   the same entry with the keys added;
//! - an HTTP entry: Codex refuses a `command` beside its `url` ("url is not supported for
//!   stdio"), so cmux passes no server of its own and sends nothing;
//! - none, an error, or no answer within [`TIMEOUT`]: nothing is sent for the person's entry.
//!
//! Skip on doubt (decided 2026-11-15, after a review saw Codex answer "none" and the launch then
//! load an HTTP `cmux` entry, so cmux's command merged into its url and Codex exited with "url
//! is not supported for stdio"). When cmux cannot be sure what the launch loads, it adds no
//! server at all, neither its own nor env keys for the person's, and says nothing: Codex starts
//! with the person's config untouched, and the agent has no cmux tools, as when the question is
//! unanswered. Doubt is any of:
//!
//! - no answer from Codex (an error, unreadable output, or over [`TIMEOUT`]): [`CmuxEntry::Unknown`];
//! - a `.codex/config.toml` from the launch folder up to the repository root (the nearest folder
//!   with `.git`; the launch folder alone outside a repository), for the folder as written and as
//!   resolved (`-C` applied), that defines `mcp_servers.cmux` and that Codex's answer does not
//!   show it loads (the answer is not that same stdio entry): an untrusted folder the person may
//!   trust at Codex's prompt, a `--trust` launch, a `-C <link>` whose trust key is the link's
//!   path. The person's user config (`$CODEX_HOME/config.toml`) is not a project file. A file
//!   that does not parse but names `cmux` counts too. [`project_doubt`], [`CmuxEntry::Doubt`];
//! - a terminal launch whose loaded config can differ from the question
//!   ([`launch_doubt`]): `--trust`, `--worktree`, `--ignore-user-config`, `--remote`, resume and
//!   fork in every form (`resume`, `fork`, `exec resume`, `review` of a session), and any
//!   subcommand outside the new-session ones (none, `exec`, `review`). An agent chat's launch is
//!   always `codex app-server` in the chat's own folder, resumed or forked in that same folder,
//!   which is the folder Codex is asked about.
//!
//! Every other field of a person's `cmux` entry merges into this build's server where cmux gives
//! its own: extra `env` keys, `env_vars`, timeouts, `enabled_tools`/`disabled_tools`,
//! `environment_id` (a remote executor), `required` and `scopes` (cmux-tui
//! agent_computer_use.rs). The acpmux guest mode of a `cmux acp desktop link` entry is sent
//! empty (`agent_tools::cmux_server`).

use std::ffi::OsString;
use std::path::{Component, Path, PathBuf};
use std::time::{Duration, Instant};

use crate::agent_tools::CMUX_SERVER as SERVER;

/// The longest `codex mcp get` may take; a slower one is no answer.
pub const TIMEOUT: Duration = Duration::from_secs(2);

/// The person's own `cmux` entry for a Codex launch, as `codex mcp get` gives it.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum CmuxEntry {
    /// No server named `cmux`.
    None,
    /// A stdio server: its exact command and args.
    Stdio { command: String, args: Vec<String> },
    /// A server over HTTP (`streamable_http`, or any transport that is not stdio).
    Http,
    /// No answer: Codex failed, printed what this does not read, or took over [`TIMEOUT`].
    Unknown,
    /// Codex answered, but what the launch loads may differ from it ([`project_doubt`]): a
    /// project file defining `cmux` that Codex's answer does not show it loads. The reason.
    Doubt(String),
}

impl CmuxEntry {
    /// Whether this build's server cannot take the name: the person's is HTTP.
    pub fn is_http(&self) -> bool {
        matches!(self, Self::Http)
    }

    /// Whether cmux adds no server at all to this launch (neither its own nor env keys for the
    /// person's), and says nothing: the person's is HTTP, or what the launch loads is in doubt
    /// (no answer, or [`CmuxEntry::Doubt`]). Codex then starts with the person's config as it is.
    pub fn skips(&self) -> bool {
        matches!(self, Self::Http | Self::Unknown | Self::Doubt(_))
    }
}

/// The options of the person's Codex arguments that decide which config Codex loads: `-C`/`--cd`
/// (the launch folder), and the ones `mcp get` takes too (`-c`/`--config`, `-p`/`--profile`,
/// `--enable`, `--disable`), in every form clap accepts.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct ConfigArgs {
    /// `-C DIR` / `--cd DIR`, as given (relative to the launch folder).
    pub cd: Option<PathBuf>,
    /// The config options, in order, as `mcp get` takes them (`-c VALUE`, `-p NAME`,
    /// `--enable F`, `--disable F`).
    pub passed: Vec<OsString>,
}

/// The value of option `long` (or its `short` letter) when `arg` is one: the
/// next argument for `-x`/`--long`, or the attached one in `-xVALUE`,
/// `-x=VALUE` and `--long=VALUE`. `Some(None)` means it takes the next one.
fn option_value<'a>(arg: &'a str, short: char, long: &str) -> Option<Option<&'a str>> {
    if let Some(rest) = arg.strip_prefix("--").and_then(|rest| rest.strip_prefix(long)) {
        return match rest.strip_prefix('=') {
            Some(value) => Some(Some(value)),
            None if rest.is_empty() => Some(None),
            None => None,
        };
    }
    let rest = arg.strip_prefix('-')?.strip_prefix(short)?;
    if arg.starts_with("--") {
        return None;
    }
    if rest.is_empty() {
        return Some(None);
    }
    Some(Some(rest.strip_prefix('=').unwrap_or(rest)))
}

/// `-C` and the config options in Codex's argument list `args` (until `--`); the last `-C` wins,
/// as for clap.
pub fn config_args(args: &[OsString]) -> ConfigArgs {
    let mut found = ConfigArgs::default();
    let mut args = args.iter();
    while let Some(raw) = args.next() {
        let Some(arg) = raw.to_str() else { continue };
        if arg == "--" {
            break;
        }
        let options: [(char, &str, &str); 5] = [
            ('C', "cd", ""),
            ('p', "profile", "-p"),
            ('c', "config", "-c"),
            ('\0', "enable", "--enable"),
            ('\0', "disable", "--disable"),
        ];
        for (short, long, flag) in options {
            let Some(value) = option_value(arg, short, long) else { continue };
            let Some(value) = value.map(OsString::from).or_else(|| args.next().cloned()) else {
                break;
            };
            if short == 'C' {
                found.cd = Some(PathBuf::from(value));
            } else {
                found.passed.push(OsString::from(flag));
                found.passed.push(value);
            }
            break;
        }
    }
    found
}

/// The home folder as Codex finds it (dirs::home_dir): `HOME` when it is set
/// and not empty, else the account's home (`dirs::home_dir`: the user database
/// on Unix).
pub fn home_dir(getenv: &dyn Fn(&str) -> Option<OsString>) -> Option<PathBuf> {
    getenv("HOME").filter(|home| !home.is_empty()).map(PathBuf::from).or_else(dirs::home_dir)
}

/// The folder a launch's session runs in, as Codex computes it: the launch
/// folder joined with `-C`'s (a leading `~` expanded with `home`), `.` and
/// `..` removed lexically, links kept (codex-utils-absolute-path
/// `relative_to_current_dir`, Codex 0.160.1 and 0.169.0).
fn launch_folder(cwd: &Path, cd: Option<&Path>, home: Option<&Path>) -> PathBuf {
    let cd = cd.map(|cd| match (cd.strip_prefix("~"), home) {
        (Ok(rest), Some(home)) => home.join(rest),
        _ => cd.to_path_buf(),
    });
    let joined = cd.map_or_else(|| cwd.to_path_buf(), |cd| cwd.join(cd));
    let mut clean = PathBuf::new();
    for component in joined.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                clean.pop();
            }
            other => clean.push(other.as_os_str()),
        }
    }
    clean
}

/// The person's own `cmux` entry for a launch of `codex` (the program the launch runs) with the
/// person's arguments `args` in `cwd`: `codex <config options> mcp get cmux --json` in the launch
/// folder (`-C` applied), with exactly `env` (the Codex child's environment), within
/// [`TIMEOUT`], then [`project_doubt`] over the project files. Also how long it took.
pub fn resolve(
    codex: &Path,
    args: &[OsString],
    cwd: &Path,
    env: &[(OsString, OsString)],
) -> (CmuxEntry, Duration) {
    let started = Instant::now();
    let entry = resolve_within(codex, args, cwd, env, TIMEOUT);
    (entry, started.elapsed())
}

fn resolve_within(
    codex: &Path,
    args: &[OsString],
    cwd: &Path,
    env: &[(OsString, OsString)],
    timeout: Duration,
) -> CmuxEntry {
    let deadline = Instant::now() + timeout;
    resolve_until(codex, args, cwd, env, deadline, |child| child.exited_within(timeout))
}

/// [`resolve_within`] with the wait for the child's exit supplied: `exited` reports whether it
/// exited by `deadline`. Tests end the wait on an event of their own instead of a wall clock.
fn resolve_until(
    codex: &Path,
    args: &[OsString],
    cwd: &Path,
    env: &[(OsString, OsString)],
    deadline: Instant,
    exited: impl FnOnce(&mut cmux_process::Child) -> std::io::Result<bool>,
) -> CmuxEntry {
    use std::io::Read as _;
    let config = config_args(args);
    let getenv = |key: &str| env.iter().find(|(k, _)| k == key).map(|(_, v)| v.clone());
    let home = home_dir(&getenv);
    let folder = launch_folder(cwd, config.cd.as_deref(), home.as_deref());
    let mut command = cmux_process::Command::new(codex);
    command
        .args(&config.passed)
        .args(["mcp", "get", SERVER, "--json"])
        .current_dir(&folder)
        .env_clear()
        .envs(env.iter().map(|(k, v)| (k, v)))
        .stdin(cmux_process::Stdio::null())
        .stdout(cmux_process::Stdio::piped())
        .stderr(cmux_process::Stdio::piped())
        // Its own process group, so a timeout ends whatever it started too.
        .process_group(0);
    let Ok(mut child) = command.spawn() else { return CmuxEntry::Unknown };
    // Each pipe is read on a thread of its own, which sends what it read when the pipe closes.
    // A reader that cannot start drops its sender, so its receiver reads as no answer.
    let read = |name: &str, pipe: Option<Box<dyn std::io::Read + Send>>| {
        let (tx, rx) = std::sync::mpsc::channel();
        if let Some(mut pipe) = pipe {
            let _ = std::thread::Builder::new().name(name.to_owned()).spawn(move || {
                let mut text = String::new();
                let _ = pipe.read_to_string(&mut text);
                let _ = tx.send(text);
            });
        }
        rx
    };
    let stdout = read(
        "codex-mcp-get-stdout",
        child.stdout.take().map(|p| Box::new(p) as Box<dyn std::io::Read + Send>),
    );
    let stderr = read(
        "codex-mcp-get-stderr",
        child.stderr.take().map(|p| Box::new(p) as Box<dyn std::io::Read + Send>),
    );
    // Unreaped until after the group kill below, so the group id cannot name another process.
    let exited = exited(&mut child);
    // Whatever it started and left running ends with it, so no process outlives the question
    // and nothing it left holds the output open.
    #[cfg(unix)]
    {
        let group = child.id() as libc::pid_t;
        // SAFETY: a signal to the process group this call started, whose leader is not yet
        // reaped; no memory is touched.
        unsafe { libc::kill(-group, libc::SIGKILL) };
    }
    #[cfg(not(unix))]
    let _ = child.kill();
    // The reap. A child still running at the deadline was just killed, so this returns at once.
    let status = child.wait();
    let status = match (exited, status) {
        (Ok(true), Ok(status)) => status,
        _ => return CmuxEntry::Unknown,
    };
    // The output, by the same deadline: a pipe something outside the group (a process that left
    // it) still holds open is a late answer, and a late answer is no answer. Its reader thread
    // ends when that pipe closes.
    let collect = |rx: &std::sync::mpsc::Receiver<String>| {
        rx.recv_timeout(deadline.saturating_duration_since(Instant::now())).ok()
    };
    let (Some(out), Some(err)) = (collect(&stdout), collect(&stderr)) else {
        return CmuxEntry::Unknown;
    };
    let entry = entry_from(status.success(), &out, &err);
    if entry == CmuxEntry::Unknown {
        return entry;
    }
    let user = getenv("CODEX_HOME")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .or_else(|| home.as_ref().map(|h| h.join(".codex")))
        .map(|dir| dir.join("config.toml"));
    match project_doubt(&folder, user.as_deref(), &entry) {
        Some(why) => CmuxEntry::Doubt(why),
        None => entry,
    }
}

/// Why what a launch in `folder` loads may differ from Codex's answer `entry`: a
/// `.codex/config.toml` from `folder` up to the repository root (the nearest folder with `.git`;
/// outside a repository, `folder`'s own only), for `folder` as written and as resolved, that defines
/// `mcp_servers.cmux` (or does not parse but names `cmux`) and is not the entry Codex answered
/// (the same stdio command and args). `user` (the person's user config) is no project file. A
/// read-only scan that only ever adds doubt: it never makes cmux send anything.
pub fn project_doubt(folder: &Path, user: Option<&Path>, entry: &CmuxEntry) -> Option<String> {
    let user = user.and_then(|u| u.canonicalize().ok().or_else(|| Some(u.to_path_buf())));
    let resolved = folder.canonicalize().ok();
    let mut files: Vec<PathBuf> = Vec::new();
    for start in std::iter::once(folder.to_path_buf()).chain(resolved) {
        // Outside a repository, the launch folder is the project root.
        let root = start
            .ancestors()
            .find(|dir| dir.join(".git").exists())
            .map_or_else(|| start.clone(), Path::to_path_buf);
        for dir in start.ancestors() {
            let file = dir.join(".codex/config.toml");
            if !files.contains(&file) {
                files.push(file);
            }
            if dir == root {
                break;
            }
        }
    }
    for file in files {
        let Ok(text) = std::fs::read_to_string(&file) else { continue };
        let real = file.canonicalize().unwrap_or_else(|_| file.clone());
        if user.as_deref() == Some(real.as_path()) {
            continue;
        }
        let shown = file.display();
        let Ok(config) = text.parse::<toml::Table>() else {
            if text.contains(SERVER) {
                return Some(format!("{shown} does not parse and names {SERVER}"));
            }
            continue;
        };
        let Some(table) = config.get("mcp_servers").and_then(|s| s.get(SERVER)) else { continue };
        let command = table.get("command").and_then(toml::Value::as_str);
        let args: Option<Vec<&str>> = match table.get("args") {
            None => Some(Vec::new()),
            Some(toml::Value::Array(list)) => list.iter().map(toml::Value::as_str).collect(),
            Some(_) => None,
        };
        let loaded = match entry {
            CmuxEntry::Stdio { command: c, args: a } => {
                command == Some(c.as_str())
                    && args
                        .is_some_and(|args| args.iter().copied().eq(a.iter().map(String::as_str)))
            }
            _ => false,
        };
        if !loaded {
            return Some(format!(
                "{shown} defines {SERVER}, and Codex's answer does not show it loads"
            ));
        }
    }
    None
}

/// Why a terminal launch of Codex with the person's arguments `args` may load another config than
/// the question asked ([`resolve`] asks for a new session in the launch folder), or `None` for a
/// new session: no subcommand (an interactive session, with or without a prompt), `exec`, or
/// `review`, with none of `--trust`, `--worktree`, `--ignore-user-config` or `--remote`. Resume
/// and fork in every form (`resume`, `fork`, `exec resume`, `exec fork`, `--last`) and every other
/// subcommand are doubt.
pub fn launch_doubt(args: &[OsString]) -> Option<String> {
    const DOUBT_FLAGS: [&str; 6] =
        ["--trust", "--worktree", "--ignore-user-config", "--remote", "--last", "--resume"];
    const VALUE_OPTIONS: [&str; 22] = [
        "-c",
        "--config",
        "-p",
        "--profile",
        "-C",
        "--cd",
        "-m",
        "--model",
        "-s",
        "--sandbox",
        "-a",
        "--ask-for-approval",
        "-i",
        "--image",
        "--enable",
        "--disable",
        "--add-dir",
        "--local-provider",
        "--output-schema",
        "-o",
        "--output-last-message",
        "--color",
    ];
    const SUBCOMMANDS: [&str; 36] = [
        "exec",
        "e",
        "review",
        "login",
        "logout",
        "mcp",
        "mcp-server",
        "app-server",
        "completion",
        "sandbox",
        "debug",
        "apply",
        "a",
        "resume",
        "fork",
        "cloud",
        "features",
        "help",
        "proto",
        "generate-ts",
        "responses-api-proxy",
        "stdio-to-uds",
        "execpolicy",
        "agents",
        "plugin",
        "update",
        "queue",
        "archive",
        "delete",
        "unarchive",
        "migrate-rollouts",
        "migrate-nfs-db",
        "remote-control",
        "app",
        "doctor",
        "exec-server",
    ];
    let mut positionals: Vec<&str> = Vec::new();
    let mut args = args.iter().filter_map(|a| a.to_str());
    while let Some(arg) = args.next() {
        if arg == "--" {
            break;
        }
        let flag = arg.split_once('=').map_or(arg, |(f, _)| f);
        if DOUBT_FLAGS.contains(&flag) {
            return Some(format!("the launch passes {flag}"));
        }
        if arg.starts_with('-') {
            if VALUE_OPTIONS.contains(&arg) {
                args.next();
            }
            continue;
        }
        positionals.push(arg);
    }
    // Any word that names a subcommand other than a new session's, wherever it stands (an option
    // this list does not know may have taken the word before it): doubt. A prompt is one word
    // (quoted), so it is never one of these.
    let new_session = |word: &str| matches!(word, "exec" | "e" | "review");
    positionals
        .iter()
        .find(|word| SUBCOMMANDS.contains(word) && !new_session(word))
        .map(|word| format!("the launch names `{word}`"))
}

/// [`CmuxEntry`] from `codex mcp get cmux --json`'s exit (`ok`), stdout and stderr: Codex 0.160.1
/// and 0.169.0 print `{"transport": {"type": "stdio", "command", "args"}}` or
/// `{"transport": {"type": "streamable_http", ...}}`, and exit 1 with "No MCP server named
/// 'cmux' found." when there is none.
fn entry_from(ok: bool, stdout: &str, stderr: &str) -> CmuxEntry {
    if !ok {
        return if stderr.contains("No MCP server named") {
            CmuxEntry::None
        } else {
            CmuxEntry::Unknown
        };
    }
    let Ok(answer) = serde_json::from_str::<serde_json::Value>(stdout) else {
        return CmuxEntry::Unknown;
    };
    let Some(transport) = answer.get("transport") else { return CmuxEntry::Unknown };
    match transport["type"].as_str() {
        Some("stdio") => {
            let Some(command) = transport["command"].as_str() else { return CmuxEntry::Unknown };
            let args = match &transport["args"] {
                serde_json::Value::Null => Some(Vec::new()),
                serde_json::Value::Array(list) => {
                    list.iter().map(|a| a.as_str().map(str::to_owned)).collect()
                }
                _ => None,
            };
            match args {
                Some(args) => CmuxEntry::Stdio { command: command.to_owned(), args },
                None => CmuxEntry::Unknown,
            }
        }
        Some(_) => CmuxEntry::Http,
        None => CmuxEntry::Unknown,
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    fn os(args: &[&str]) -> Vec<OsString> {
        args.iter().map(OsString::from).collect()
    }

    #[test]
    fn config_args_keeps_the_options_mcp_get_takes_in_order() {
        let found = config_args(&os(&[
            "-C",
            "../x",
            "-pwork",
            "-c",
            "a=1",
            "--enable",
            "f",
            "--disable=g",
            "exec",
            "hi",
        ]));
        assert_eq!(found.cd, Some(PathBuf::from("../x")));
        assert_eq!(
            found.passed,
            os(&["-p", "work", "-c", "a=1", "--enable", "f", "--disable", "g"])
        );
        assert_eq!(config_args(&os(&["--cd=/w"])).cd, Some(PathBuf::from("/w")));
        assert_eq!(
            config_args(&os(&["--config=mcp_servers.cmux.command=/x"])).passed,
            os(&["-c", "mcp_servers.cmux.command=/x"])
        );
        // After `--`, and inside a prompt: not an option.
        assert_eq!(config_args(&os(&["--", "-p", "a"])), ConfigArgs::default());
        assert_eq!(config_args(&os(&["fix -p bug"])), ConfigArgs::default());
    }

    #[test]
    fn the_launch_folder_is_cleaned_as_codex_does() {
        let w = Path::new("/w/a");
        assert_eq!(launch_folder(w, Some(Path::new("../b/./c")), None), Path::new("/w/b/c"));
        assert_eq!(launch_folder(w, None, None), w);
        let home = Some(Path::new("/h"));
        assert_eq!(launch_folder(w, Some(Path::new("~/x")), home), Path::new("/h/x"));
        assert_eq!(launch_folder(w, Some(Path::new("/../x")), home), Path::new("/x"));
    }

    /// Codex's answers, as Codex 0.160.1 and 0.169.0 print them.
    #[test]
    fn each_answer_of_codex_reads_as_its_entry() {
        let stdio = r#"{"name":"cmux","enabled":true,"transport":{"type":"stdio","command":"/opt/x","args":["a","b c"],"env":{"K":"v"},"env_vars":[],"cwd":null}}"#;
        assert_eq!(
            entry_from(true, stdio, ""),
            CmuxEntry::Stdio { command: "/opt/x".into(), args: vec!["a".into(), "b c".into()] }
        );
        let no_args = r#"{"transport":{"type":"stdio","command":"/x","args":null}}"#;
        assert_eq!(
            entry_from(true, no_args, ""),
            CmuxEntry::Stdio { command: "/x".into(), args: vec![] }
        );
        let http = r#"{"transport":{"type":"streamable_http","url":"http://127.0.0.1:9/mcp"}}"#;
        assert_eq!(entry_from(true, http, ""), CmuxEntry::Http);
        assert_eq!(
            entry_from(false, "", "Error: No MCP server named 'cmux' found.\n"),
            CmuxEntry::None
        );
        for (ok, out, err) in [
            (false, "", "Error: failed to load config"),
            (true, "not json", ""),
            (true, r#"{"transport":{}}"#, ""),
            (true, r#"{"transport":{"type":"stdio","command":7}}"#, ""),
            (true, r#"{"transport":{"type":"stdio","command":"/x","args":"a"}}"#, ""),
        ] {
            assert_eq!(entry_from(ok, out, err), CmuxEntry::Unknown, "{out} {err}");
        }
    }

    /// A fake `codex` that answers `mcp get` with `answer` (a shell snippet), and records the
    /// arguments and the folder it ran with.
    fn fake_codex(dir: &Path, answer: &str) -> PathBuf {
        use std::os::unix::fs::PermissionsExt as _;
        let path = dir.join("codex");
        let log = dir.join("calls");
        std::fs::write(
            &path,
            format!("#!/bin/sh\nprintf '%s|%s\\n' \"$(pwd -P)\" \"$*\" >> {log:?}\n{answer}\n"),
        )
        .unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        path
    }

    /// The resolver runs the launch's program with the person's config options and `mcp get cmux
    /// --json`, in the launch folder (`-C` applied), and reads each answer; a slow one is none.
    #[test]
    fn the_resolver_asks_codex_in_the_launch_folder_with_the_persons_options() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let work = root.join("work");
        std::fs::create_dir_all(work.join("sub")).unwrap();
        let env = vec![(OsString::from("HOME"), root.clone().into_os_string())];
        let stdio = r#"printf '{"transport":{"type":"stdio","command":"/opt/x","args":["a"]}}'"#;
        let codex = fake_codex(&root, stdio);
        let (entry, took) =
            resolve(&codex, &os(&["-C", "sub", "-p", "w", "exec", "hi"]), &work, &env);
        assert_eq!(entry, CmuxEntry::Stdio { command: "/opt/x".into(), args: vec!["a".into()] });
        assert!(took < TIMEOUT, "{took:?}");
        let calls = std::fs::read_to_string(root.join("calls")).unwrap();
        assert_eq!(
            calls.trim(),
            format!("{}|-p w mcp get cmux --json", work.join("sub").display())
        );
        let none =
            fake_codex(&root, "echo \"Error: No MCP server named 'cmux' found.\" >&2; exit 1");
        assert_eq!(resolve(&none, &[], &work, &env).0, CmuxEntry::None);
        let http = fake_codex(&root, r#"printf '{"transport":{"type":"streamable_http"}}'"#);
        assert_eq!(resolve(&http, &[], &work, &env).0, CmuxEntry::Http);
        let slow = fake_codex(&root, "exec sleep 5");
        let started = Instant::now();
        assert_eq!(
            resolve_within(&slow, &[], &work, &env, Duration::from_millis(200)),
            CmuxEntry::Unknown
        );
        assert!(started.elapsed() < Duration::from_secs(2), "{:?}", started.elapsed());
        assert_eq!(resolve(&root.join("missing"), &[], &work, &env).0, CmuxEntry::Unknown);
    }

    /// A timeout ends the resolver's whole process group: what it started is gone too. So does an
    /// answer: what it left running cannot hold the question open.
    #[test]
    fn a_timed_out_resolver_ends_with_everything_it_started() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let pid_file = root.join("pid");
        let written = root.join("pid.tmp");
        let slow = fake_codex(
            &root,
            &format!("sleep 30 & echo $! > {written:?}; mv {written:?} {pid_file:?}; wait"),
        );
        // The deadline passes once the resolver's child has started its own (the pid file is
        // there), not at a wall-clock time a loaded runner may reach before the shell gets there.
        let timed_out = std::cell::Cell::new(None);
        let entry = resolve_until(&slow, &[], &root, &[], Instant::now(), |_| {
            let deadline = Instant::now() + Duration::from_secs(30);
            while !pid_file.exists() {
                assert!(Instant::now() < deadline, "the fake codex never started its child");
                std::thread::sleep(Duration::from_millis(5));
            }
            timed_out.set(Some(Instant::now()));
            Ok(false)
        });
        assert_eq!(entry, CmuxEntry::Unknown);
        let ended = timed_out.get().unwrap().elapsed();
        assert!(ended < Duration::from_secs(2), "{ended:?}");
        let left = fake_codex(
            &root,
            r#"sleep 30 & printf '{"transport":{"type":"streamable_http"}}'; exit 0"#,
        );
        let started = Instant::now();
        assert_eq!(resolve(&left, &[], &root, &[]).0, CmuxEntry::Http);
        assert!(started.elapsed() < Duration::from_secs(2), "{:?}", started.elapsed());
        let pid: libc::pid_t = std::fs::read_to_string(&pid_file).unwrap().trim().parse().unwrap();
        // Signalled with the group; gone once its new parent reaps it.
        let deadline = Instant::now() + Duration::from_secs(5);
        // SAFETY: a probe signal (0) to a pid; nothing is sent.
        while unsafe { libc::kill(pid, 0) } == 0 {
            assert!(Instant::now() < deadline, "the resolver's child {pid} still runs");
            std::thread::yield_now();
        }
    }

    /// A process that leaves the resolver's group and keeps its output open makes the answer late,
    /// and a late answer is no answer: the resolver ends by its deadline, never on that process.
    #[test]
    fn an_answer_still_open_at_the_deadline_is_no_answer() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let pid_file = root.join("pid");
        let escaped = fake_codex(
            &root,
            &format!(
                "perl -MPOSIX -e 'setsid(); open(my $f, \">\", \"{}\"); print $f \"$$\"; close $f; sleep 30' &\n\
                 while [ ! -s \"{}\" ]; do :; done\n\
                 printf '{{\"transport\":{{\"type\":\"streamable_http\"}}}}'; exit 0",
                pid_file.display(),
                pid_file.display()
            ),
        );
        let started = Instant::now();
        assert_eq!(
            resolve_within(&escaped, &[], &root, &[], Duration::from_millis(500)),
            CmuxEntry::Unknown
        );
        assert!(started.elapsed() < Duration::from_secs(2), "{:?}", started.elapsed());
        let deadline = Instant::now() + Duration::from_secs(5);
        while !pid_file.exists() && Instant::now() < deadline {
            std::thread::yield_now();
        }
        if let Ok(pid) = std::fs::read_to_string(&pid_file)
            && let Ok(pid) = pid.trim().parse::<libc::pid_t>()
        {
            // SAFETY: ends the test's own escaped process; no memory is touched.
            unsafe { libc::kill(pid, libc::SIGKILL) };
        }
    }

    /// Outside a repository only the launch folder's own project file counts: a parent folder's
    /// is not this project's.
    #[test]
    fn outside_a_repository_only_the_launch_folder_counts() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let leaf = root.join("a/b");
        std::fs::create_dir_all(leaf.join(".codex")).unwrap();
        std::fs::create_dir_all(root.join("a/.codex")).unwrap();
        let http = "[mcp_servers.cmux]\nurl = \"http://x\"\n";
        std::fs::write(root.join("a/.codex/config.toml"), http).unwrap();
        assert_eq!(project_doubt(&leaf, None, &CmuxEntry::None), None, "a parent's file");
        std::fs::write(leaf.join(".codex/config.toml"), http).unwrap();
        assert!(project_doubt(&leaf, None, &CmuxEntry::None).is_some(), "its own file");
    }

    /// A project file defining `cmux` that Codex's answer does not show it loads is doubt: from
    /// the launch folder up to the repository root, for the folder as written (a link) and as
    /// resolved; the person's user config is none, nor is a folder above the root.
    #[test]
    fn a_project_cmux_entry_codex_does_not_show_it_loads_is_doubt() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let repo = root.join("repo");
        let deep = repo.join("a/b");
        std::fs::create_dir_all(&deep).unwrap();
        std::fs::create_dir_all(repo.join(".git")).unwrap();
        let none = CmuxEntry::None;
        let stdio = CmuxEntry::Stdio { command: "/opt/x".into(), args: vec!["mcp".into()] };
        let write = |dir: &Path, text: &str| {
            std::fs::create_dir_all(dir.join(".codex")).unwrap();
            std::fs::write(dir.join(".codex/config.toml"), text).unwrap();
        };
        assert_eq!(project_doubt(&deep, None, &none), None, "no project file");
        // Above the repository root: not this project's.
        write(&root, "[mcp_servers.cmux]\nurl = \"http://x\"\n");
        assert_eq!(project_doubt(&deep, None, &none), None);
        // In the middle, HTTP: doubt whatever Codex answered but that same stdio entry.
        write(&repo.join("a"), "[mcp_servers.cmux]\nurl = \"http://x\"\n");
        for entry in [&none, &stdio, &CmuxEntry::Http] {
            assert!(project_doubt(&deep, None, entry).is_some(), "{entry:?}");
        }
        write(&repo.join("a"), "[mcp_servers.cmux]\ncommand = \"/opt/x\"\nargs = [\"mcp\"]\n");
        assert_eq!(project_doubt(&deep, None, &stdio), None, "the entry Codex loads");
        assert!(project_doubt(&deep, None, &none).is_some(), "one Codex does not load");
        write(&repo.join("a"), "[mcp_servers.other]\nurl = \"http://x\"\n");
        assert_eq!(project_doubt(&deep, None, &none), None, "another name");
        write(&repo.join("a"), "[mcp_servers.cmux\nbroken");
        assert!(project_doubt(&deep, None, &none).is_some(), "unparseable, names cmux");
        write(&repo.join("a"), "[broken");
        assert_eq!(project_doubt(&deep, None, &none), None, "unparseable, no cmux");
        // The person's user config, when the repository is their home: not a project file.
        write(&repo, "[mcp_servers.cmux]\nurl = \"http://x\"\n");
        let user = repo.join(".codex/config.toml");
        assert_eq!(project_doubt(&deep, Some(&user), &none), None);
        assert!(project_doubt(&deep, None, &none).is_some());
        std::fs::remove_dir_all(repo.join(".codex")).unwrap();
        std::fs::remove_dir_all(root.join(".codex")).unwrap();
        std::fs::remove_dir_all(repo.join("a/.codex")).unwrap();
        // A link (`-C <link>`): the target's project files count, though the link's path is
        // outside the repository.
        let link = root.join("link");
        std::os::unix::fs::symlink(&deep, &link).unwrap();
        write(&deep, "[mcp_servers.cmux]\nurl = \"http://x\"\n");
        assert!(project_doubt(&link, None, &none).is_some());
        // Through `resolve`: Codex answers none, the project file makes it doubt.
        let env = vec![(OsString::from("HOME"), root.join("home").into_os_string())];
        let codex =
            fake_codex(&root, "echo \"Error: No MCP server named 'cmux' found.\" >&2; exit 1");
        assert!(matches!(
            resolve(&codex, &os(&["-C", "link", "exec", "hi"]), &root, &env).0,
            CmuxEntry::Doubt(_)
        ));
    }

    /// The launches whose loaded config can differ from the question are doubt; a new session
    /// (none, a prompt, `exec`, `review`) is not.
    #[test]
    fn launches_that_may_load_another_config_are_doubt() {
        for args in [
            &[][..],
            &["fix it"],
            &["exec", "fix it"],
            &["e", "-C", "/w", "hi"],
            &["review", "--uncommitted"],
            &["-c", "a=1", "-p", "resume", "exec", "hi"],
            &["exec", "--", "resume"],
            &["exec", "fix the resume bug"],
        ] {
            assert_eq!(launch_doubt(&os(args)), None, "{args:?}");
        }
        for args in [
            &["--trust"][..],
            &["exec", "--trust", "hi"],
            &["--worktree"],
            &["--worktree=x"],
            &["--ignore-user-config"],
            &["--remote", "ws://h"],
            &["resume"],
            &["resume", "--last"],
            &["fork", "019a"],
            &["exec", "resume", "--last"],
            &["e", "fork", "019a"],
            &["--last"],
            &["agents"],
            &["mcp", "list"],
            &["app-server"],
            &["--some-new-option", "value", "resume", "--last"],
            &["exec", "--new-flag", "x", "fork"],
        ] {
            assert!(launch_doubt(&os(args)).is_some(), "{args:?}");
        }
    }
}
