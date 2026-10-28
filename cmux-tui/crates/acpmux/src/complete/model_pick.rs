//! The harness's small model when the caller names none (design
//! "Which model, and whose auth"):
//!
//! - Claude Code ([`claude_model`]): `ANTHROPIC_SMALL_FAST_MODEL` when the
//!   profile env (or the login env) sets one; else the `haiku` alias, so the
//!   user's own mapping (`ANTHROPIC_DEFAULT_HAIKU_MODEL` on Bedrock, Vertex,
//!   CodeRouter) picks the concrete model. A concrete newest
//!   `claude-haiku-*` only when Claude Code's live list lacks the alias or
//!   the backend refused it; never from the curated catalog.
//! - Codex: the first `luna`, then `mini`, then `nano` model it lists
//!   (effort low is the recipe's); else the CLI's default.
//! - The others: the first `flash-lite`, `flash`, `haiku`, `luna` or `mini`
//!   model, in that order; else the CLI's default.
//!
//! Words match at a word start, so `gemini` is not a `mini`.

use super::recipes::Recipe;

/// Claude Code's alias for its current Haiku.
pub const CLAUDE_FALLBACK: &str = "haiku";
/// Claude Code's own small-model override.
pub const SMALL_FAST_ENV: &str = "ANTHROPIC_SMALL_FAST_MODEL";
/// The user's own mapping of the `haiku` alias (Bedrock, Vertex, CodeRouter).
pub const DEFAULT_HAIKU_ENV: &str = "ANTHROPIC_DEFAULT_HAIKU_MODEL";

const CODEX_ORDER: &[&str] = &["luna", "mini", "nano"];
const OTHER_ORDER: &[&str] = &["flash-lite", "flash", "haiku", "luna", "mini"];

/// The model for `recipe` from the ids the harness offers. None: the CLI's
/// default. Claude Code's is [`claude_model`]; here it is the alias.
pub fn pick(recipe: Recipe, ids: &[String]) -> Option<String> {
    match recipe {
        Recipe::Claude => Some(CLAUDE_FALLBACK.to_owned()),
        Recipe::Codex => first_word_match(ids, CODEX_ORDER),
        Recipe::OpenCode | Recipe::Pi | Recipe::Omp | Recipe::Grok => {
            first_word_match(ids, OTHER_ORDER)
        }
    }
}

/// What Claude Code's small model is chosen from.
#[derive(Debug, Default, Clone, Copy)]
pub struct ClaudeInputs<'a> {
    /// `ANTHROPIC_SMALL_FAST_MODEL`, when set.
    pub small_fast: Option<&'a str>,
    /// `ANTHROPIC_DEFAULT_HAIKU_MODEL`, when set: the user maps the alias.
    pub default_haiku: Option<&'a str>,
    /// Claude Code's own live model list, when one arrived (never the catalog).
    pub live: Option<&'a [String]>,
    /// Ids the backend refused (`model_availability.rs`).
    pub refused: &'a [String],
}

/// Claude Code's small model.
pub fn claude_model(inputs: &ClaudeInputs<'_>) -> String {
    if let Some(model) = inputs.small_fast.map(str::trim).filter(|m| !m.is_empty()) {
        return model.to_owned();
    }
    // The user maps the alias to their provider's model: Claude Code resolves it.
    if inputs.default_haiku.is_some_and(|m| !m.trim().is_empty()) {
        return CLAUDE_FALLBACK.to_owned();
    }
    let is_alias = |m: &String| m.eq_ignore_ascii_case(CLAUDE_FALLBACK);
    let listed = inputs.live.is_none_or(|live| live.iter().any(is_alias));
    let refused = inputs.refused.iter().any(is_alias);
    if listed && !refused {
        return CLAUDE_FALLBACK.to_owned();
    }
    let usable: Vec<String> = inputs
        .live
        .unwrap_or_default()
        .iter()
        .filter(|m| !inputs.refused.contains(*m))
        .cloned()
        .collect();
    newest_haiku(&usable).unwrap_or_else(|| CLAUDE_FALLBACK.to_owned())
}

/// The first id holding `order[0]`, else `order[1]`, ...
fn first_word_match(ids: &[String], order: &[&str]) -> Option<String> {
    order.iter().find_map(|word| ids.iter().find(|id| has_word(id, word)).cloned())
}

/// Whether `id` holds `word` at a word start (after the start, `-`, `/`,
/// `.`, `_` or `:`) and not followed by another letter. `flash` is not in
/// `flash-lite`'s place: callers order `flash-lite` first.
pub fn has_word(id: &str, word: &str) -> bool {
    let id = id.to_ascii_lowercase();
    let mut from = 0;
    while let Some(at) = id.get(from..).and_then(|rest| rest.find(word)) {
        let start = from + at;
        let end = start + word.len();
        let before = id.get(..start).and_then(|head| head.chars().next_back());
        let after = id.get(end..).and_then(|tail| tail.chars().next());
        let starts = before.is_none_or(|c| !c.is_ascii_alphanumeric());
        let ends = after.is_none_or(|c| !c.is_ascii_alphabetic());
        if starts && ends {
            return true;
        }
        from = start + 1;
        while from < id.len() && !id.is_char_boundary(from) {
            from += 1;
        }
    }
    false
}

/// The newest `claude-haiku-*` id: the highest version, then the latest
/// date (`claude-haiku-5-5` over `claude-haiku-4-5-20251001`).
pub fn newest_haiku(ids: &[String]) -> Option<String> {
    ids.iter()
        .filter_map(|id| haiku_version(id).map(|v| (v, id)))
        .max_by(|(a, _), (b, _)| a.cmp(b))
        .map(|(_, id)| id.clone())
}

/// `(version parts, date)` of a `claude-haiku-<n>-<n>[-<yyyymmdd>]` id.
fn haiku_version(id: &str) -> Option<(Vec<u64>, u64)> {
    let lower = id.to_ascii_lowercase();
    let rest = lower.strip_prefix("claude-haiku-")?;
    let (mut version, mut date) = (Vec::new(), 0);
    for part in rest.split(['-', '.']) {
        let Ok(n) = part.parse::<u64>() else { break };
        if part.len() >= 6 {
            date = n;
        } else {
            version.push(n);
        }
    }
    (!version.is_empty()).then_some((version, date))
}
