//! Whether a Codex launch can take cmux's MCP server under the name `cmux`:
//! one rule for both ways cmux gives it, the `codex` terminal shim (cmux-tui
//! `agent_computer_use.rs` `codex_settings`) and Codex agent chats (acpmux
//! `agent_tools::acp_servers_for`, through cmux-codex-acp's thread config).
//!
//! Both pass the server's `command`, `args`, `env`, `cwd` and `enabled = true`
//! under `cmux`, which Codex merges key by key into a `cmux` entry its config
//! layers already make. Codex refuses a server that has both a command
//! and an HTTP-only field (`url`, `bearer_token_env_var`, `http_headers`,
//! `env_http_headers`, `oauth_resource`: "url is not supported for stdio",
//! checked live with Codex 0.160.1 and 0.169.0), and `-c` cannot take a key
//! out. So where the person has their own HTTP server named `cmux` in a
//! config Codex may load for this launch, the shim passes no server: the
//! person's server keeps the name, and Codex starts. That is the user config
//! (`$CODEX_HOME/config.toml`, `~/.codex/config.toml` without it), the
//! `--profile` file (`$CODEX_HOME/<name>.config.toml`) when the launch names
//! one, and each `.codex/config.toml` from the launch folder (`-C` applied)
//! up to `/`, on the folder as written (`.`/`..` removed lexically, as Codex
//! does) and on the folder its links resolve to. A project file counts
//! whether or not Codex trusts the project yet (it may, after its prompt). A
//! file that cannot be read or parsed is no conflict: Codex reports it
//! itself.
//!
//! Every other field of a person's `cmux` entry merges into this build's
//! server for that launch: extra `env` keys, `env_vars`, timeouts,
//! `enabled_tools`/`disabled_tools`, `environment_id` (a remote executor),
//! `required` and `scopes` (module docs of cmux-tui agent_computer_use.rs).
//! The acpmux guest mode of a `cmux acp desktop link` entry is sent empty
//! (`agent_tools::cmux_server`).

use std::ffi::OsString;
use std::path::{Component, Path, PathBuf};

use crate::agent_tools::CMUX_SERVER as SERVER;

/// The fields of a Codex MCP entry that only an HTTP server may have.
const HTTP_ONLY: [&str; 5] =
    ["url", "bearer_token_env_var", "http_headers", "env_http_headers", "oauth_resource"];

/// The options of the person's Codex arguments that choose the config files:
/// `-C`/`--cd` and `-p`/`--profile`, in every form clap accepts.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct ConfigArgs {
    /// `-C DIR` / `--cd DIR`, as given (relative to the launch folder).
    pub cd: Option<PathBuf>,
    /// `-p NAME` / `--profile NAME`.
    pub profile: Option<OsString>,
    /// Each `-c KEY=VALUE` / `--config KEY=VALUE`, as given.
    pub overrides: Vec<String>,
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

/// `-C` and `-p` in Codex's argument list `args` (until `--`); the last of
/// each wins, as for clap.
pub fn config_args(args: &[OsString]) -> ConfigArgs {
    let mut found = ConfigArgs::default();
    let mut args = args.iter();
    while let Some(raw) = args.next() {
        let Some(arg) = raw.to_str() else { continue };
        if arg == "--" {
            break;
        }
        for (short, long) in [('C', "cd"), ('p', "profile"), ('c', "config")] {
            let Some(value) = option_value(arg, short, long) else { continue };
            let Some(value) = value.map(OsString::from).or_else(|| args.next().cloned()) else {
                break;
            };
            match short {
                'C' => found.cd = Some(PathBuf::from(value)),
                'p' => found.profile = Some(value),
                _ => found.overrides.extend(value.to_str().map(str::to_owned)),
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

/// Whether the Codex config at `file` has an MCP server named `cmux` with an
/// HTTP-only field. A file that is not there, or cannot be read or parsed,
/// has none.
fn names_http_cmux(file: &Path) -> bool {
    let Ok(text) = std::fs::read_to_string(file) else { return false };
    let Ok(config) = text.parse::<toml::Table>() else { return false };
    config
        .get("mcp_servers")
        .and_then(|servers| servers.get(SERVER))
        .and_then(toml::Value::as_table)
        .is_some_and(|entry| HTTP_ONLY.iter().any(|field| entry.contains_key(*field)))
}

/// Whether one of the person's own `-c` values gives the server named `cmux`
/// an HTTP-only field (`-c mcp_servers.cmux.url=…`, or a whole table
/// `-c mcp_servers.cmux={url=…}`).
fn names_http_cmux_override(overrides: &[String]) -> bool {
    overrides.iter().any(|value| {
        let Some((key, raw)) = value.split_once('=') else { return false };
        let key: Vec<&str> = key.trim().split('.').collect();
        match key.as_slice() {
            ["mcp_servers", name, field, ..] if *name == SERVER => HTTP_ONLY.contains(field),
            ["mcp_servers", name] if *name == SERVER => format!("v = {raw}")
                .parse::<toml::Table>()
                .ok()
                .and_then(|t| t.get("v").and_then(toml::Value::as_table).cloned())
                .is_some_and(|entry| HTTP_ONLY.iter().any(|f| entry.contains_key(*f))),
            _ => false,
        }
    })
}

/// Whether a config Codex may load for this launch has the person's own HTTP
/// server named `cmux` (module docs): then this build's server cannot take
/// the name, and the shim passes none. `args` are the person's Codex
/// arguments, `cwd` the launch folder, `getenv` the pane's environment.
pub fn http_cmux_entry(
    args: &[OsString],
    cwd: &Path,
    getenv: &dyn Fn(&str) -> Option<OsString>,
) -> bool {
    let config = config_args(args);
    if names_http_cmux_override(&config.overrides) {
        return true;
    }
    let home = home_dir(getenv);
    let codex_home = getenv("CODEX_HOME")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .or_else(|| home.as_ref().map(|home| home.join(".codex")));
    let mut files = Vec::new();
    if let Some(codex_home) = &codex_home {
        files.push(codex_home.join("config.toml"));
        if let Some(profile) = &config.profile {
            let mut name = profile.clone();
            name.push(".config.toml");
            files.push(codex_home.join(name));
        }
    }
    let written = launch_folder(cwd, config.cd.as_deref(), home.as_deref());
    let resolved = written.canonicalize().unwrap_or_else(|_| written.clone());
    for folder in [&written, &resolved] {
        files.extend(folder.ancestors().map(|ancestor| ancestor.join(".codex/config.toml")));
    }
    files.iter().any(|file| names_http_cmux(file))
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    fn os(args: &[&str]) -> Vec<OsString> {
        args.iter().map(OsString::from).collect()
    }

    #[test]
    fn config_args_reads_cd_and_profile_in_every_form() {
        let found = config_args(&os(&["-C", "../x", "-pwork", "exec", "hi"]));
        assert_eq!(found.cd, Some(PathBuf::from("../x")));
        assert_eq!(found.profile, Some(OsString::from("work")));
        assert_eq!(config_args(&os(&["--cd=/w"])).cd, Some(PathBuf::from("/w")));
        assert_eq!(config_args(&os(&["-C/w"])).cd, Some(PathBuf::from("/w")));
        assert_eq!(config_args(&os(&["--profile", "a"])).profile, Some(OsString::from("a")));
        assert_eq!(config_args(&os(&["-p=a"])).profile, Some(OsString::from("a")));
        // After `--`, and inside a prompt: not an option.
        assert_eq!(config_args(&os(&["--", "-p", "a"])), ConfigArgs::default());
        assert_eq!(config_args(&os(&["fix -p bug"])), ConfigArgs::default());
    }

    /// The person's own `-c` naming an HTTP field of `cmux`, in any form, counts as an HTTP
    /// entry; their other `-c` values do not.
    #[test]
    fn an_http_cmux_override_on_the_command_line_counts() {
        let none = |_: &str| None;
        let cwd = Path::new("/");
        for args in [
            &["-c", "mcp_servers.cmux.url=\"http://x\""][..],
            &["--config=mcp_servers.cmux.bearer_token_env_var=\"T\"", "exec", "hi there"],
            &["-cmcp_servers.cmux.http_headers={a=\"b\"}"],
            &["-c", "mcp_servers.cmux={url=\"http://x\"}"],
        ] {
            assert!(http_cmux_entry(&os(args), cwd, &none), "{args:?}");
        }
        for args in [
            &["-c", "mcp_servers.cmux.cwd=\"/w\""][..],
            &["-c", "mcp_servers.other.url=\"http://x\""],
            &["-c", "model=\"o3\""],
            &["exec", "--", "-c", "mcp_servers.cmux.url=x"],
        ] {
            assert!(!http_cmux_entry(&os(args), cwd, &none), "{args:?}");
        }
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

    /// An HTTP `cmux` entry is found in the user config, the named profile's
    /// file and a project folder above the launch folder (written or
    /// resolved); a stdio one, another server's or an unreadable file is no
    /// conflict.
    #[test]
    fn an_http_cmux_entry_is_found_where_codex_may_load_it() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let (home, codex_home) = (root.join("home"), root.join("codex-home"));
        let sub = root.join("w/proj/sub");
        for folder in [&home, &codex_home, &sub] {
            std::fs::create_dir_all(folder).unwrap();
        }
        let write = |path: PathBuf, text: &str| {
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, text).unwrap();
        };
        let env = |key: &str| match key {
            "HOME" => Some(home.clone().into_os_string()),
            "CODEX_HOME" => Some(codex_home.clone().into_os_string()),
            _ => None,
        };
        let http = "[mcp_servers.cmux]\nurl = \"http://127.0.0.1:1/mcp\"\n";
        let found = |args: &[&str]| http_cmux_entry(&os(args), &sub, &env);
        assert!(!found(&[]));
        write(codex_home.join("config.toml"), http);
        assert!(found(&[]));
        write(
            codex_home.join("config.toml"),
            "[mcp_servers.cmux]\ncommand = \"/x\"\ncwd = \"/y\"\n",
        );
        assert!(!found(&[]), "a stdio entry");
        write(codex_home.join("config.toml"), "[mcp_servers.other]\nurl = \"http://x\"\n");
        assert!(!found(&[]), "another server");
        write(codex_home.join("config.toml"), "[mcp_servers.cmux\nurl = 1");
        assert!(!found(&[]), "a file Codex itself refuses");
        std::fs::remove_file(codex_home.join("config.toml")).unwrap();
        // The profile's file, only with that profile.
        write(codex_home.join("work.config.toml"), http);
        assert!(found(&["--profile", "work"]) && !found(&[]));
        std::fs::remove_file(codex_home.join("work.config.toml")).unwrap();
        // A project folder above, and `-C` into or out of it.
        write(
            root.join("w/.codex/config.toml"),
            "[mcp_servers.cmux]\nbearer_token_env_var = \"T\"\n",
        );
        assert!(found(&[]));
        assert!(!http_cmux_entry(&os(&["-C", "/"]), &sub, &env));
        assert!(http_cmux_entry(&os(&["-C", "w/proj"]), &root, &env));
        // Through a link: the folder as written and the resolved one both count.
        std::fs::create_dir_all(root.join("elsewhere")).unwrap();
        std::os::unix::fs::symlink(root.join("elsewhere"), root.join("w/link")).unwrap();
        assert!(http_cmux_entry(&os(&["-C", "w/link"]), &root, &env), "written");
        std::os::unix::fs::symlink(&sub, root.join("into")).unwrap();
        assert!(http_cmux_entry(&os(&[]), &root.join("into"), &env), "resolved");
        // Without CODEX_HOME: ~/.codex is the user config.
        std::fs::remove_dir_all(root.join("w/.codex")).unwrap();
        write(home.join(".codex/config.toml"), http);
        let home_only = |key: &str| (key == "HOME").then(|| home.clone().into_os_string());
        assert!(http_cmux_entry(&os(&[]), &sub, &home_only));
    }

    /// The home folder as Codex finds it (dirs::home_dir): `HOME` when it is
    /// set and not empty, else the account's home from the user database.
    #[test]
    fn an_empty_home_falls_back_to_the_accounts_home() {
        let set = |key: &str| (key == "HOME").then(|| OsString::from("/h"));
        assert_eq!(home_dir(&set), Some(PathBuf::from("/h")));
        let empty = |key: &str| (key == "HOME").then(OsString::new);
        let account = home_dir(&empty).expect("the account has a home");
        assert!(account.is_absolute() && account != Path::new(""), "{account:?}");
        assert_eq!(home_dir(&|_: &str| None), Some(account));
    }
}
