//! The harness's small model when the caller names none (design
//! "Which model, and whose auth"):
//!
//! - Claude Code: `ANTHROPIC_SMALL_FAST_MODEL` when the profile env (or the
//!   login env) sets one, so Vertex and Bedrock users keep theirs; else the
//!   newest `claude-haiku-*` the live list or catalog offers; else `haiku`.
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

const CODEX_ORDER: &[&str] = &["luna", "mini", "nano"];
const OTHER_ORDER: &[&str] = &["flash-lite", "flash", "haiku", "luna", "mini"];

/// The model for `recipe` from the ids the harness offers. `small_fast`:
/// the `ANTHROPIC_SMALL_FAST_MODEL` value, when set. None: the CLI's default.
pub fn pick(recipe: Recipe, ids: &[String], small_fast: Option<&str>) -> Option<String> {
    // hq#1957: not implemented yet (the failing tests come first).
    let _ = (recipe, ids, small_fast);
    None
}

/// The first id holding `order[0]`, else `order[1]`, ...
fn first_word_match(ids: &[String], order: &[&str]) -> Option<String> {
    order.iter().find_map(|word| ids.iter().find(|id| has_word(id, word)).cloned())
}

/// Whether `id` holds `word` at a word start (after the start, `-`, `/`,
/// `.`, `_` or `:`) and not followed by another letter. `flash` is not in
/// `flash-lite`'s place: callers order `flash-lite` first.
pub fn has_word(id: &str, word: &str) -> bool {
    // hq#1957: not implemented yet (the failing tests come first).
    let _ = (id, word);
    false
}

/// The newest `claude-haiku-*` id: the highest version, then the latest
/// date (`claude-haiku-5-5` over `claude-haiku-4-5-20251001`).
pub fn newest_haiku(ids: &[String]) -> Option<String> {
    // hq#1957: not implemented yet (the failing tests come first).
    let _ = ids;
    None
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
