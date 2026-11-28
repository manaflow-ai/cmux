//! The headless recipes: for each harness that has one, the program and the
//! exact argv of a tool-less, MCP-less, hook-less, session-less one-shot.
//! The flags are the ones classic cmux used for auto-naming
//! (origin/main `CLI/CMUXCLI+AutoNaming.swift` and
//! `CMUXCLI+AutoNamingSummarizers.swift`).
//!
//! Claude Code and Codex read the prompt on stdin. OpenCode, pi, omp and
//! Grok read it from a file in the run's own folder, as classic did.

use super::CompleteError;
use crate::config::{HarnessKind, HarnessProfile};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// A harness's headless recipe.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Recipe {
    /// Claude Code (`claude`, `claude-sr`, `claude-cr`): `claude -p`.
    Claude,
    /// `codex exec`.
    Codex,
    /// `opencode run`.
    OpenCode,
    /// `pi --print`.
    Pi,
    /// `omp --print`.
    Omp,
    /// `grok --prompt-file`.
    Grok,
}

/// Claude Code validates `--mcp-config` against a schema that needs an
/// `mcpServers` record (cmux#9457).
pub const EMPTY_MCP_CONFIG: &str = r#"{"mcpServers":{}}"#;
pub const NO_HOOKS_SETTINGS: &str = r#"{"disableAllHooks":true}"#;
/// OpenCode: every permission denied, as a local agent rule a user-global
/// allow cannot override.
pub const OPENCODE_ISOLATION_CONFIG: &str = r#"{"agent":{"build":{"permission":{"*":"deny"}}}}"#;
pub const OPENCODE_DENY_ALL: &str = r#"{"*":"deny"}"#;
/// The message beside a prompt file.
pub const FILE_INSTRUCTION: &str =
    "Follow the instructions in the attached file. Output only the answer.";

/// The recipe of profile `name`, or why it has none.
pub fn recipe_for(name: &str, profile: &HarnessProfile) -> Result<Recipe, CompleteError> {
    let unsupported =
        |why: &str| CompleteError::Unsupported { harness: name.to_owned(), why: why.to_owned() };
    match profile.kind {
        HarnessKind::Terminal => {
            return Err(unsupported("a terminal harness has no headless mode"));
        }
        HarnessKind::ClaudeStdio => return Ok(Recipe::Claude),
        HarnessKind::Acp => {}
    }
    match crate::config::derive_family(name, profile).as_str() {
        "codex" => Ok(Recipe::Codex),
        "opencode" => Ok(Recipe::OpenCode),
        "pi" => Ok(Recipe::Pi),
        "omp" => Ok(Recipe::Omp),
        "grok" => Ok(Recipe::Grok),
        "gemini" => Err(unsupported("Gemini has no tool-less headless mode")),
        "claude" => Err(unsupported("a Claude ACP adapter; use the Claude Code harness")),
        _ => Err(unsupported("no headless recipe for this harness")),
    }
}

fn file_name(path: &str) -> String {
    Path::new(path).file_name().map(|f| f.to_string_lossy().into_owned()).unwrap_or_default()
}

/// The program to run and the words that go before the recipe's own: the
/// profile's own program for Claude Code with only its launcher words (the
/// leading words before any flag: `sr claude proxy`, `cr <route>`), never
/// a flag the profile pins (`--mcp-config` would start its MCP servers,
/// `--dangerously-skip-permissions` or `--output-format` would change the
/// run); `claude` when the argv is empty, as the chat path does. The real
/// CLI for the others (their
/// profiles start an ACP adapter or subcommand). `env` is the profile's
/// (with its route); `which` looks a program up on the login PATH. None:
/// not installed.
pub fn program(
    recipe: Recipe,
    profile: &HarnessProfile,
    env: &BTreeMap<String, String>,
    which: &dyn Fn(&str) -> Option<String>,
) -> Option<(String, Vec<String>)> {
    let first = profile.argv.first().filter(|p| !p.is_empty());
    let own_or = |bin: &str| first.filter(|p| file_name(p) == bin).cloned().or_else(|| which(bin));
    let program = match recipe {
        Recipe::Claude => {
            let Some((program, rest)) = profile.argv.split_first().filter(|(p, _)| !p.is_empty())
            else {
                return Some(("claude".to_owned(), Vec::new()));
            };
            let launcher = rest.iter().take_while(|w| !w.starts_with('-')).cloned().collect();
            return Some((program.clone(), launcher));
        }
        // The configured Codex (`CODEX_PATH`, as the ACP adapter runs it).
        Recipe::Codex => env
            .get("CODEX_PATH")
            .filter(|p| !p.is_empty() && !p.contains("${"))
            .cloned()
            .or_else(|| own_or("codex")),
        Recipe::OpenCode | Recipe::Omp | Recipe::Grok => first.cloned(),
        // The profile starts the pi-acp adapter; the CLI is `pi`.
        Recipe::Pi => own_or("pi"),
    }?;
    Some((program, Vec::new()))
}

/// How one completion runs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Invocation {
    pub program: String,
    pub args: Vec<String>,
    /// The prompt goes on stdin; else it is written to `prompt_file` first.
    pub stdin_prompt: bool,
    pub prompt_file: Option<PathBuf>,
    /// Where the answer is read from instead of stdout (Codex).
    pub output_file: Option<PathBuf>,
    pub env_set: Vec<(String, String)>,
    pub env_remove: Vec<String>,
}

impl Invocation {
    /// `codex exec` with the user's provider overrides (`codex_config`), each
    /// as `-c <value>` right after `exec`.
    pub fn with_codex_overrides(mut self, overrides: &[String]) -> Self {
        let at = self.args.iter().position(|a| a == "exec").map_or(0, |i| i + 1);
        let pairs = overrides.iter().flat_map(|o| ["-c".to_owned(), o.clone()]);
        let _ = self.args.splice(at..at, pairs);
        self
    }
}

fn strings(words: &[&str]) -> Vec<String> {
    words.iter().map(|w| (*w).to_owned()).collect()
}

/// The folders of one run (`places.rs`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Folders<'a> {
    /// The fixed empty cwd every run shares.
    pub cwd: &'a Path,
    /// This run's own folder: the prompt and output files.
    pub run: &'a Path,
}

/// The invocation of `recipe` with `program` and `prefix` (from
/// [`program`]), `model` (None: the CLI's default), in `folders`.
pub fn invocation(
    recipe: Recipe,
    program: String,
    prefix: Vec<String>,
    model: Option<&str>,
    folders: Folders<'_>,
) -> Invocation {
    let dir = folders.run;
    let model = model.filter(|m| !m.is_empty() && *m != "default");
    let prompt_path = dir.join("prompt.txt");
    let prompt_arg = prompt_path.to_string_lossy().into_owned();
    let mut args = prefix;
    let mut out = Invocation {
        program,
        args: Vec::new(),
        stdin_prompt: false,
        prompt_file: None,
        output_file: None,
        env_set: Vec::new(),
        env_remove: Vec::new(),
    };
    match recipe {
        Recipe::Claude => {
            args.extend(strings(&["-p", "--output-format", "text", "--model"]));
            args.push(model.unwrap_or(super::model_pick::CLAUDE_FALLBACK).to_owned());
            args.extend(strings(&[
                "--tools",
                "",
                "--disable-slash-commands",
                "--no-session-persistence",
                "--strict-mcp-config",
                "--mcp-config",
                EMPTY_MCP_CONFIG,
                "--settings",
                NO_HOOKS_SETTINGS,
            ]));
            out.stdin_prompt = true;
        }
        Recipe::Codex => {
            let last = dir.join("last-message.txt");
            args.extend(strings(&[
                "exec",
                "--ephemeral",
                "--skip-git-repo-check",
                "--ignore-user-config",
                "--ignore-rules",
                "--sandbox",
                "read-only",
                "-c",
                "default_tools_enabled=false",
                "-c",
                "tools={}",
                "-c",
                "mcp_servers={}",
                "-c",
                "web_search=\"disabled\"",
                "-c",
                "approval_policy=never",
                "-c",
                "shell_environment_policy.inherit=none",
                "-c",
                "model_reasoning_effort=low",
            ]));
            if let Some(m) = model {
                args.extend(["-m".to_owned(), m.to_owned()]);
            }
            args.extend([
                "--output-last-message".to_owned(),
                last.to_string_lossy().into_owned(),
                "-".to_owned(),
            ]);
            out.stdin_prompt = true;
            out.output_file = Some(last);
        }
        Recipe::OpenCode => {
            args.extend(strings(&["run", "--pure", "--format", "default", "--dir"]));
            args.push(folders.cwd.to_string_lossy().into_owned());
            if let Some(m) = model {
                args.extend(["--model".to_owned(), m.to_owned()]);
            }
            args.extend(["--file".to_owned(), prompt_arg, FILE_INSTRUCTION.to_owned()]);
            out.prompt_file = Some(prompt_path);
            out.env_remove =
                strings(&["OPENCODE_CONFIG", "OPENCODE_CONFIG_DIR", "OPENCODE_PROJECT_CONFIG"]);
            out.env_set = vec![
                ("OPENCODE_DISABLE_PROJECT_CONFIG".into(), "1".into()),
                ("OPENCODE_CONFIG_CONTENT".into(), OPENCODE_ISOLATION_CONFIG.into()),
                ("OPENCODE_PERMISSION".into(), OPENCODE_DENY_ALL.into()),
                ("OPENCODE_PURE".into(), "1".into()),
            ];
        }
        Recipe::Pi | Recipe::Omp => {
            args.extend(strings(&[
                "--print",
                "--no-tools",
                "--no-session",
                "--no-extensions",
                "--no-skills",
            ]));
            // omp isolates context with rules and refuses pi's two flags.
            if recipe == Recipe::Pi {
                args.extend(strings(&["--no-prompt-templates", "--no-context-files"]));
            } else {
                args.push("--no-rules".to_owned());
            }
            if let Some(m) = model {
                args.extend(["--model".to_owned(), m.to_owned()]);
            }
            args.extend([format!("@{prompt_arg}"), FILE_INSTRUCTION.to_owned()]);
            out.prompt_file = Some(prompt_path);
        }
        Recipe::Grok => {
            args.extend(["--prompt-file".to_owned(), prompt_arg]);
            args.extend(strings(&[
                "--output-format",
                "plain",
                "--tools",
                "",
                "--disable-web-search",
                "--no-subagents",
                "--no-memory",
                "--verbatim",
            ]));
            if let Some(m) = model {
                args.extend(["--model".to_owned(), m.to_owned()]);
            }
            out.prompt_file = Some(prompt_path);
        }
    }
    out.args = args;
    out
}
