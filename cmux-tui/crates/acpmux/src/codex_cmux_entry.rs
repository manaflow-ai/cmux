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
//! One known gap: `mcp get` reads project files for its working folder as resolved, so a launch
//! with `-C <a link>` whose trust key is the link's path (which `codex exec -C` honours) reads
//! as no entry, and nothing is sent: the person's entry then starts as a caller outside cmux.
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
}

impl CmuxEntry {
    /// Whether this build's server cannot take the name: the person's is HTTP.
    pub fn is_http(&self) -> bool {
        matches!(self, Self::Http)
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
/// [`TIMEOUT`]. Also how long it took.
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
    use std::io::Read as _;
    let config = config_args(args);
    let getenv = |key: &str| env.iter().find(|(k, _)| k == key).map(|(_, v)| v.clone());
    let folder = launch_folder(cwd, config.cd.as_deref(), home_dir(&getenv).as_deref());
    let mut command = std::process::Command::new(codex);
    command
        .args(&config.passed)
        .args(["mcp", "get", SERVER, "--json"])
        .current_dir(&folder)
        .env_clear()
        .envs(env.iter().map(|(k, v)| (k, v)))
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped());
    let Ok(mut child) = command.spawn() else { return CmuxEntry::Unknown };
    let read = |pipe: Option<Box<dyn std::io::Read + Send>>| {
        pipe.map(|mut pipe| {
            std::thread::spawn(move || {
                let mut text = String::new();
                let _ = pipe.read_to_string(&mut text);
                text
            })
        })
    };
    let stdout = read(child.stdout.take().map(|p| Box::new(p) as Box<dyn std::io::Read + Send>));
    let stderr = read(child.stderr.take().map(|p| Box::new(p) as Box<dyn std::io::Read + Send>));
    let deadline = Instant::now() + timeout;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            // One short-lived child, polled in 10 ms steps: std has no wait with a timeout.
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(10)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return CmuxEntry::Unknown;
            }
        }
    };
    let out = stdout.and_then(|r| r.join().ok()).unwrap_or_default();
    let err = stderr.and_then(|r| r.join().ok()).unwrap_or_default();
    entry_from(status.success(), &out, &err)
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
    let transport = &answer["transport"];
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
}
