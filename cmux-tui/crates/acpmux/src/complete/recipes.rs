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
    // hq#1957: not implemented yet (the failing tests come first).
    let _ = profile;
    Err(CompleteError::Unsupported { harness: name.to_owned(), why: "not implemented".into() })
}

fn file_name(path: &str) -> String {
    Path::new(path).file_name().map(|f| f.to_string_lossy().into_owned()).unwrap_or_default()
}

/// The program to run and the words that go before the recipe's own: the
/// profile's own command for Claude Code (a wrapper such as
/// `sr claude proxy` keeps its words), the real CLI for the others (their
/// profiles start an ACP adapter or subcommand). `env` is the profile's
/// (with its route); `which` looks a program up on the login PATH. None:
/// not installed.
pub fn program(
    recipe: Recipe,
    profile: &HarnessProfile,
    env: &BTreeMap<String, String>,
    which: &dyn Fn(&str) -> Option<String>,
) -> Option<(String, Vec<String>)> {
    // hq#1957: not implemented yet (the failing tests come first).
    let _ = (recipe, profile, env, which);
    None
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

fn strings(words: &[&str]) -> Vec<String> {
    words.iter().map(|w| (*w).to_owned()).collect()
}

/// The invocation of `recipe` with `program` and `prefix` (from
/// [`program`]), `model` (None: the CLI's default), in `dir`, the run's own
/// fresh folder.
pub fn invocation(
    recipe: Recipe,
    program: String,
    prefix: Vec<String>,
    model: Option<&str>,
    dir: &Path,
) -> Invocation {
    // hq#1957: not implemented yet (the failing tests come first).
    let _ = (recipe, prefix, model, dir);
    Invocation {
        program,
        args: Vec::new(),
        stdin_prompt: false,
        prompt_file: None,
        output_file: None,
        env_set: Vec::new(),
        env_remove: Vec::new(),
    }
}
