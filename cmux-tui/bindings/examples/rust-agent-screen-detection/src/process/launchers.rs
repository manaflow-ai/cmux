//! Agent launcher shapes that a process name alone does not reveal.
//!
//! Adapted from herdr's `src/detect/mod.rs` (https://github.com/ogulcancelik/herdr,
//! Apache-2.0, see `manifests/LICENSE`). The package-launcher paths and the
//! Cursor bundled-node check follow commit
//! `7b675f42af35508eab66ac42fe1598628597a893` with the Pi correction from
//! `b1ff4582e9688f52ffb943cfa8bee4871ae122e4`. At commit
//! `2563803dca97c040beaf3dc3acdcb5a3221b4238` this file also follows the Kimi
//! and omp package launchers (63ea2314, cd8306d7), Cline's hidden `.cline`
//! launcher (f3cbe03f), Letta interactivity (fc1cb77f) and the Hermes Python
//! installer signature (e35f3937). Modified by manaflow: results are manifest
//! ids for the replaceable catalog instead of a closed agent enum, and the
//! Letta entrypoint check reuses this plugin's runtime option grammar.

use super::{ForegroundProcess, is_eval_invocation, normalized_name, path_candidates};

pub(super) fn known_package_agent(effective: &str, argv: &[String]) -> Option<String> {
    let runtime = normalized_name(effective);
    if runtime != "node" && runtime != "bun" {
        return None;
    }
    // A package-shaped path can be script text in an attached eval flag.
    // Check the runtime grammar before applying the path-specific launcher
    // exception, or eval text could claim an agent identity.
    if is_eval_invocation(&runtime, argv) {
        return None;
    }
    argv.get(1).and_then(|script| known_package_path_agent(script))
}

pub(super) fn known_package_path_agent(path: &str) -> Option<String> {
    let raw_components =
        path.split(['/', '\\']).filter(|component| !component.is_empty()).collect::<Vec<_>>();
    let ends_with = |suffix: &[&str]| {
        raw_components.len() >= suffix.len()
            && raw_components[raw_components.len() - suffix.len()..]
                .iter()
                .zip(suffix)
                .all(|(actual, expected)| actual.eq_ignore_ascii_case(expected))
    };
    // Pi's current Windows package emits either the direct CLI or the
    // bundled CLI entrypoint. Compare raw components here. Normalizing file
    // extensions first would turn `cli.exe` into `cli` and accept an invalid
    // executable as a live agent.
    if ends_with(&["node_modules", "@earendil-works", "pi-coding-agent", "dist", "cli.js"])
        || ends_with(&[
            "node_modules",
            "@earendil-works",
            "pi-coding-agent",
            "dist",
            "bundle",
            "cli.js",
        ])
    {
        return Some("pi".into());
    }
    // npm installs of oh-my-pi and Kimi Code run these exact entrypoints.
    if ends_with(&["node_modules", "@oh-my-pi", "pi-coding-agent", "dist", "cli.js"]) {
        return Some("omp".into());
    }
    if ends_with(&["node_modules", "@moonshot-ai", "kimi-code", "dist", "main.mjs"]) {
        return Some("kimi".into());
    }

    let components = raw_components.into_iter().map(normalized_name).collect::<Vec<_>>();
    for window in components.windows(5) {
        if window == ["node_modules", "@qwen-code", "qwen-code", "dist", "index"] {
            return Some("qwen".into());
        }
    }
    for window in components.windows(4) {
        if window == ["node_modules", "mastracode", "dist", "cli"] {
            return Some("mastracode".into());
        }
    }
    // pnpm's package exposes opencode through `opencode-ai/bin/opencode`.
    if components.windows(3).any(|window| window == ["opencode-ai", "bin", "opencode"]) {
        return Some("opencode".into());
    }
    None
}

pub(super) fn cursor_bundled_agent(argv: &[String]) -> Option<String> {
    let runtime = argv.first().map(|value| normalized_name(value))?;
    if runtime != "node" {
        return None;
    }
    let runtime_path = argv.first()?;
    let script_path = argv.get(1)?;
    let (runtime_parent, runtime_name) = path_parent_and_basename(runtime_path)?;
    let (script_parent, script_name) = path_parent_and_basename(script_path)?;
    if !runtime_name.eq_ignore_ascii_case("node.exe")
        || !script_name.eq_ignore_ascii_case("index.js")
        || !runtime_parent.eq_ignore_ascii_case(script_parent)
    {
        return None;
    }
    let mut tail = runtime_parent.rsplit(['/', '\\']).filter(|component| !component.is_empty());
    let (Some(version), Some(versions), Some(package)) = (tail.next(), tail.next(), tail.next())
    else {
        return None;
    };
    (package.eq_ignore_ascii_case("cursor-agent")
        && versions.eq_ignore_ascii_case("versions")
        && !version.is_empty())
    .then(|| "cursor".into())
}

fn path_parent_and_basename(path: &str) -> Option<(&str, &str)> {
    let split = path.rfind(['/', '\\'])?;
    let parent = path[..split].trim_end_matches(['/', '\\']);
    let basename = &path[split + 1..];
    (!parent.is_empty() && !basename.is_empty()).then_some((parent, basename))
}

/// Cline's npm package runs a hidden native launcher, `bin/.cline`. The
/// launcher name is evidence for the `cline` manifest; other dot-names are not.
pub(super) fn with_hidden_launcher_aliases(mut candidates: Vec<String>) -> Vec<String> {
    let hidden_cline = candidates.iter().any(|candidate| {
        let basename = candidate.rsplit(['/', '\\']).find(|part| !part.is_empty());
        basename.is_some_and(|name| {
            let name = name.to_ascii_lowercase();
            name == ".cline" || name == ".cline.exe"
        })
    });
    if hidden_cline && !candidates.iter().any(|candidate| candidate == "cline") {
        candidates.push("cline".into());
    }
    candidates
}

// ---- Letta ----------------------------------------------------------------

const LETTA_NONINTERACTIVE_OPTIONS: &[&str] = &[
    "-p",
    "--print",
    "--prompt",
    "--json",
    "--stream-json",
    "--run",
    "--disable-memory-guard",
    "--output-format",
    "--input-format",
    "--include-partial-messages",
    "--from-agent",
    "--environment",
    "--env",
    "--pre-load-skills",
    "--tags",
    "--ephemeral",
    "--stateless",
    "--max-turns",
    "--memfs-startup",
    "-h",
    "--help",
    "-v",
    "--version",
    "--info",
    "--update",
    "--upgrade",
];

fn is_letta_path(token: &str) -> bool {
    path_candidates(token).first().is_some_and(|candidate| candidate.eq_ignore_ascii_case("letta"))
}

/// Index of the Letta entrypoint in `argv`: the executable itself, or the
/// script a `node`/`bun` runtime runs.
fn letta_entrypoint_index(argv: &[String]) -> Option<usize> {
    if argv.first().is_some_and(|argument| is_letta_path(argument)) {
        return Some(0);
    }
    let runtime = normalized_name(argv.first()?);
    if runtime != "node" && runtime != "bun" {
        return None;
    }
    let mut index = 1;
    while let Some(argument) = argv.get(index) {
        if argument == "--" {
            return argv
                .get(index + 1)
                .is_some_and(|next| is_letta_path(next))
                .then_some(index + 1);
        }
        if super::is_eval_flag(&runtime, argument) {
            return None;
        }
        if argument.starts_with('-') {
            index += if super::runtime_option_takes_value(&runtime, argument) { 2 } else { 1 };
            continue;
        }
        return is_letta_path(argument).then_some(index);
    }
    None
}

/// Return whether a Letta process is an interactive session. One-shot
/// prompts, structured output, server and subcommand modes, help and version
/// are separate processes that must not claim the pane.
pub(super) fn letta_is_interactive(process: &ForegroundProcess) -> bool {
    let parsed;
    let argv = if process.argv.is_empty() {
        parsed = process
            .cmdline
            .as_deref()
            .unwrap_or_default()
            .split_whitespace()
            .map(|argument| argument.trim_matches(['\'', '"']).to_string())
            .collect::<Vec<_>>();
        if parsed.is_empty() {
            return true;
        }
        &parsed
    } else {
        &process.argv
    };
    let cli_args = letta_entrypoint_index(argv).map_or(argv.as_slice(), |index| &argv[index + 1..]);
    if cli_args.iter().any(|argument| {
        let option = argument.split_once('=').map_or(argument.as_str(), |(name, _)| name);
        LETTA_NONINTERACTIVE_OPTIONS.contains(&option)
    }) {
        return false;
    }
    let mut arguments = cli_args.iter();
    while let Some(argument) = arguments.next() {
        if argument == "--backend" {
            arguments.next();
            continue;
        }
        if argument.starts_with("--backend=") {
            continue;
        }
        // A positional first argument is a subcommand or a one-shot prompt.
        return argument.starts_with('-');
    }
    true
}

// ---- Hermes ---------------------------------------------------------------

/// Recognize the captured Hermes installer bootstrap, not arbitrary Python
/// source. Both root literals must agree; escapes and quotes are rejected
/// rather than parsed. Unknown bootstrap revisions fall back to ordinary
/// process identification.
pub(super) fn hermes_installer_agent(argv: &[String]) -> Option<String> {
    let [_, isolation, command, code, args @ ..] = argv else {
        return None;
    };
    if isolation != "-I"
        || command != "-c"
        || args.first().is_some_and(|argument| {
            matches!(argument.as_str(), "--run-module" | "--print-runtime-command")
        })
    {
        return None;
    }
    let rest = code.strip_prefix(HERMES_INSTALLER_PREFIX)?;
    let (root, rest) = rest.split_once("')\n")?;
    if root.is_empty() || root.contains(['\'', '\\', '\n', '\r']) {
        return None;
    }
    let rest = rest.strip_prefix(HERMES_INSTALLER_MIDDLE)?.strip_prefix(root)?;
    (rest == HERMES_INSTALLER_SUFFIX).then(|| "hermes".to_string())
}

// Installer source captured in herdr issue #4910. Only the installation root
// varies.
const HERMES_INSTALLER_PREFIX: &str = "import os, re, sys
os.environ.pop('PYTHONHOME', None)
os.environ.pop('PYTHONPATH', None)
sys.path.insert(0, '";
const HERMES_INSTALLER_MIDDLE: &str =
    "if sys.argv[1:2] == ['--print-runtime-command']: sys.dont_write_bytecode = True
from hermes_constants import get_default_hermes_root
os.environ['HERMES_HOME'] = os.environ.get('HERMES_HOME') or str(get_default_hermes_root())
if sys.argv[1:2] == ['--print-runtime-command']:
    from pathlib import Path
    from hermes_cli._launchers import print_runtime_command
    print_runtime_command(Path('";
const HERMES_INSTALLER_SUFFIX: &str = r"'), sys.argv[2:])
    sys.exit(0)
import hermes_bootstrap
if sys.argv[1:2] == ['--run-module']:
    import runpy
    if len(sys.argv) < 3: sys.exit('hermes: --run-module needs a module')
    module = sys.argv.pop(2)
    del sys.argv[1]
    runpy.run_module(module, run_name='__main__', alter_sys=True)
    sys.exit(0)
from hermes_cli.main import main
sys.argv[0] = re.sub(r'(-script\.pyw|\.exe)?$', '', sys.argv[0])
sys.exit(main())
";
