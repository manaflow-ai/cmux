//! The turn session's system prompt and the turn's prompt (sections 7 and 7.2).
//! Everything here is constant: the prompt and the tool list head every
//! cached prefix, so they hold no dates, no state and no per-turn text.

use serde_json::{Value, json};

// The prompt text and the tool descriptions live in the kernel's pure core,
// shared with the Cloud Chief (chief-kernel, cloud-chief-durable-DESIGN.md 13).
pub use chief_kernel::prompt::*;

/// How long a cache entry lives after its last read: Anthropic's two TTLs.
/// Every mark of one request has the same TTL (the API refuses a 1h mark
/// after a 5m one, and Claude Code places marks before and after ours).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CacheTtl {
    FiveMinutes,
    OneHour,
}

impl CacheTtl {
    /// `5m` or `1h` (the settings and env spelling).
    pub fn parse(text: &str) -> Option<CacheTtl> {
        match text.trim() {
            "5m" => Some(CacheTtl::FiveMinutes),
            "1h" => Some(CacheTtl::OneHour),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            CacheTtl::FiveMinutes => "5m",
            CacheTtl::OneHour => "1h",
        }
    }

    /// The `cache_control` of a mark: the API's default TTL is 5 minutes,
    /// so a 5m mark carries no `ttl`.
    pub fn cache_control(self) -> Value {
        match self {
            CacheTtl::FiveMinutes => json!({"type": "ephemeral"}),
            CacheTtl::OneHour => json!({"type": "ephemeral", "ttl": "1h"}),
        }
    }
}

/// The turns' cache TTL from the host env, None when it names none:
/// Claude Code's own switches first (`FORCE_PROMPT_CACHING_5M`,
/// `CLAUDE_CODE_PROMPT_CACHE_TTL`), since every turn's harness inherits
/// them and its marks must match ours, then `OPTCHAT_CACHE_TTL`.
pub fn cache_ttl_from_env(env: &dyn Fn(&str) -> Option<String>) -> Option<CacheTtl> {
    if env("FORCE_PROMPT_CACHING_5M").is_some_and(|v| !v.is_empty() && v != "0") {
        return Some(CacheTtl::FiveMinutes);
    }
    env("CLAUDE_CODE_PROMPT_CACHE_TTL")
        .as_deref()
        .and_then(CacheTtl::parse)
        .or_else(|| {
            env("OPTCHAT_CACHE_TTL")
                .as_deref()
                .and_then(CacheTtl::parse)
        })
}

/// Whether a failed turn's error is the API refusing a mark's TTL: a
/// 1-hour mark after a 5-minute one ("a ttl='1h' cache_control block must
/// not come after a ttl='5m' cache_control block"), or a route that takes
/// no `ttl` at all.
pub fn is_ttl_refused_error(error: &str) -> bool {
    let lower = error.to_ascii_lowercase();
    lower.contains("cache_control") && lower.contains("ttl")
}

/// The current cache TTL, shared by the brain (which decides it per turn)
/// and the compactor (whose nodes take the same TTL on the same route).
#[derive(Clone, Debug)]
pub struct SharedTtl(std::sync::Arc<std::sync::atomic::AtomicBool>);

impl SharedTtl {
    pub fn new(ttl: CacheTtl) -> SharedTtl {
        SharedTtl(std::sync::Arc::new(std::sync::atomic::AtomicBool::new(
            ttl == CacheTtl::OneHour,
        )))
    }

    pub fn get(&self) -> CacheTtl {
        if self.0.load(std::sync::atomic::Ordering::SeqCst) {
            CacheTtl::OneHour
        } else {
            CacheTtl::FiveMinutes
        }
    }

    pub fn set(&self, ttl: CacheTtl) {
        self.0.store(
            ttl == CacheTtl::OneHour,
            std::sync::atomic::Ordering::SeqCst,
        );
    }
}

impl Default for SharedTtl {
    /// 1 hour: the Claude Code path's default.
    fn default() -> SharedTtl {
        SharedTtl::new(CacheTtl::OneHour)
    }
}

/// Requests that go without our mark after Claude Code refused one (it
/// already placed the API's four): then the mark is tried again, since a
/// refusal costs one fast rerun and a lost mark costs the view on every
/// request.
pub const MARK_RETRY_AFTER: u32 = 10;

/// Whether our mark goes on the next request: off for `MARK_RETRY_AFTER`
/// requests after a refusal, then on again. Shared by a turn's worker.
#[derive(Clone, Debug, Default)]
pub struct MarkLatch(std::sync::Arc<std::sync::atomic::AtomicU32>);

impl MarkLatch {
    /// Whether this request carries our mark (counts a skipped one).
    pub fn take(&self) -> bool {
        use std::sync::atomic::Ordering::SeqCst;
        self.0
            .fetch_update(SeqCst, SeqCst, |n| n.checked_sub(1))
            .is_err()
    }

    /// Whether marks are off now (without counting a request).
    pub fn is_off(&self) -> bool {
        self.0.load(std::sync::atomic::Ordering::SeqCst) > 0
    }

    /// Claude Code refused our mark: the next `MARK_RETRY_AFTER` requests
    /// go without it.
    pub fn refused(&self) {
        self.0
            .store(MARK_RETRY_AFTER, std::sync::atomic::Ordering::SeqCst);
    }
}

/// Our one mark in a cached layout: the view piece it sits on
/// (`optchat_core::mark_piece`) and its TTL.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Mark {
    pub piece: usize,
    pub ttl: CacheTtl,
}

impl Mark {
    /// The mark on the last whole block of `context`, None when it has none.
    pub fn last_whole(context: &str, ttl: CacheTtl) -> Option<Mark> {
        optchat_core::mark_piece(context, None).map(|piece| Mark { piece, ttl })
    }
}

/// A prompt in the cached layout: the session's system prompt and the user
/// blocks.
#[derive(Clone, Debug, PartialEq)]
pub struct CachedPrompt {
    pub system: String,
    pub blocks: Vec<Value>,
}

/// The cached layout of `context` (a view) between `system` and `tail`
/// (spec 3.3, gist 3c190e0): `system` is the session's system prompt as is
/// (the same text for turns and compactions); the view follows in blocks of
/// 4 lines, the last whole block carrying the one `cache_control` marker
/// when `marker` (5 minutes); then `tail`. See `cached_layout_marked`.
pub fn cached_layout(system: &str, context: &str, tail: &str, marker: bool) -> CachedPrompt {
    let mark = marker
        .then(|| Mark::last_whole(context, CacheTtl::FiveMinutes))
        .flatten();
    cached_layout_marked(system, context, tail, mark)
}

/// The cached layout with our one mark on piece `mark.piece` of the view's
/// blocks, with its TTL. Claude Code puts its own breakpoints on the system
/// prompt and the request's end (three of the API's four), so one mark is
/// all a request may add. A block cut depends only on the lines before it,
/// so the next call has a boundary at this mark; `optchat_core::mark_piece`
/// keeps the next call's mark within the API's 20-block lookback of it.
pub fn cached_layout_marked(
    system: &str,
    context: &str,
    tail: &str,
    mark: Option<Mark>,
) -> CachedPrompt {
    let text = |t: &str| json!({"type": "text", "text": t});
    let pieces = optchat_core::block_pieces(context);
    let whole = pieces.len() - 1;
    let mut blocks: Vec<Value> = pieces.into_iter().map(text).collect();
    if let Some(mark) = mark.filter(|m| m.piece < whole) {
        blocks[mark.piece]["cache_control"] = mark.ttl.cache_control();
    }
    blocks.push(text(tail));
    CachedPrompt {
        system: system.to_owned(),
        blocks,
    }
}

/// A turn's cached layout: `cached_layout_marked`, and with `head_mark` the
/// `<chat>` header carries the mark's TTL too, the system prompt's own
/// entry (the reference client marks its system). A view that changed near
/// its start (an import's merges) then still reads the system prompt. Two
/// marks of ours; Claude Code places none while ours are on
/// (DISABLE_PROMPT_CACHING).
pub fn turn_layout(
    system: &str,
    context: &str,
    tail: &str,
    mark: Option<Mark>,
    head_mark: bool,
) -> CachedPrompt {
    let mut layout = cached_layout_marked(system, context, tail, mark);
    if let Some(m) = mark
        && head_mark
        && m.piece > 0
        && let Some(head) = layout.blocks.first_mut()
    {
        head["cache_control"] = m.ttl.cache_control();
    }
    layout
}

/// The compactor's layout: the same as a turn's (spec 4: a compaction is a
/// call like a turn, with its own view and its task).
pub fn cached_layout_at_marks(
    system: &str,
    context: &str,
    tail: &str,
    marker: bool,
) -> CachedPrompt {
    cached_layout(system, context, tail, marker)
}

/// The user's instructions file, `$MUX_HOME/optchat/AGENTS.md` (None when
/// missing or empty).
pub fn user_instructions(path: &std::path::Path) -> Option<String> {
    std::fs::read_to_string(path)
        .ok()
        .filter(|t| !t.trim().is_empty())
}

/// The person profile a Chief home starts with (`optchat/person.md`,
/// written once when missing; the user edits or empties it). The Chief
/// runs with no user CLAUDE.md or settings, so without it the Chief knows
/// nothing of how the user wants work done.
pub const DEFAULT_PERSON: &str = "# The user

This is the user's profile (optchat/person.md); they may edit it.

- Act without asking for safe operations: reading, searching, read-only
  commands, edits in a worktree or scratch folder. When the user asked for
  the work, do not ask \"Should I...?\"; do it and report.
- Ask first only for money, legal matters, physical actions and destructive
  actions (deleting data, force pushes, production changes).
- Do not run heavy builds or tests on this Mac when a remote build route
  (fleet, remote builder) is set up; use that route. The Chief gives such
  work to a subagent.
- When you name a page, PR, build, dashboard, job, bead or file, give its
  real URL or path.
";

/// The person profile at `path`: the default, written once when the file is
/// missing (never over an existing file); None when the user emptied it or
/// it cannot be read.
pub fn person_profile(path: &std::path::Path) -> Option<String> {
    match std::fs::read_to_string(path) {
        Ok(text) => Some(text).filter(|t| !t.trim().is_empty()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            // Written whole or not at all: a temp file, then a link that
            // never replaces a file the user made meanwhile.
            let tmp = path.with_extension(format!("md.tmp.{}", std::process::id()));
            if std::fs::write(&tmp, DEFAULT_PERSON).is_ok() {
                let _ = std::fs::hard_link(&tmp, path);
            }
            let _ = std::fs::remove_file(&tmp);
            Some(DEFAULT_PERSON.to_owned())
        }
        Err(e) => {
            crate::log::log(format!(
                "reading {}: {e}; no person profile this start",
                path.display()
            ));
            None
        }
    }
}

/// The user's part of the system prompt: the person profile, then the
/// user's instructions file. Read once per host start, so every turn's
/// prompt stays byte-identical until the host restarts.
pub fn chief_instructions(person: &std::path::Path, user: &std::path::Path) -> Option<String> {
    let parts: Vec<String> = [person_profile(person), user_instructions(user)]
        .into_iter()
        .flatten()
        .map(|t| t.trim().to_owned())
        .collect();
    (!parts.is_empty()).then(|| parts.join("\n\n"))
}

/// A turn's input in the cached layout (spec 5a): the frozen view in its
/// blocks of 4 lines, the delta's blocks, the turn's `images`, then `tail`
/// (per-turn state, never logged). Nothing per-turn goes before the delta's
/// end. With `ttl`, marks on the view's end, on the previous request's end
/// (`prev_end`, a delta block index: Bedrock has no look-back, so a read needs a
/// mark exactly where the last request wrote; hq-1f measured 0.93 without it,
/// 0.97 with it) and on the delta's end; with no previous end (a new view) the
/// `<chat>` header instead, the system prompt's own entry. Three marks of the
/// API's four.
pub fn input_layout(
    system: &str,
    view: &str,
    delta: &[String],
    prev_end: Option<usize>,
    images: &[Value],
    tail: &str,
    ttl: Option<CacheTtl>,
) -> CachedPrompt {
    let text = |t: &str| json!({"type": "text", "text": t});
    let mut blocks: Vec<Value> = optchat_core::block_pieces(view)
        .into_iter()
        .map(text)
        .collect();
    let view_end = blocks.len() - 1;
    blocks.extend(delta.iter().map(|b| text(b)));
    let delta_end = blocks.len() - 1;
    let first = match prev_end.filter(|b| *b < delta.len()) {
        Some(b) => view_end + 1 + b,
        None => 0,
    };
    if let Some(ttl) = ttl {
        for i in [first, view_end, delta_end] {
            blocks[i]["cache_control"] = ttl.cache_control();
        }
    }
    blocks.extend(images.iter().cloned());
    if !tail.is_empty() {
        blocks.push(text(tail));
    }
    CachedPrompt {
        system: system.to_owned(),
        blocks,
    }
}

/// `input_layout` without marks or system prompt: the blocks of a harness
/// with automatic prefix caching (codex), byte-stable the same way.
pub fn input_blocks(view: &str, delta: &[String], images: &[Value], tail: &str) -> Vec<Value> {
    input_layout("", view, delta, None, images, tail, None).blocks
}

/// The delta's lines from log index `from` on, as one text (a kept turn
/// session's next prompt: it holds everything before `from`). None when
/// there is none, or when a line (`id+n|`) covers ids on both sides of
/// `from`.
pub fn delta_from(delta: &[String], from: u64) -> Option<String> {
    let head = |line: &str| -> Option<(u64, u64)> {
        let (range, _) = line.split_once('|')?;
        let (id, n) = range.split_once('+')?;
        Some((id.parse().ok()?, n.parse().ok()?))
    };
    let mut out = String::new();
    // Whether the line being read (and its continuation lines) is taken.
    let mut taking = false;
    for line in delta.iter().flat_map(|b| b.split_inclusive('\n')) {
        if let Some((id, n)) = head(line) {
            if id < from && id + n > from {
                return None;
            }
            taking = id >= from;
        }
        if taking {
            out.push_str(line);
        }
    }
    (!out.is_empty()).then_some(out)
}

/// The index of the delta block that ends at log index `end` (an earlier
/// request's end): the block before the first one whose first line is at or
/// past it. None when no block ends there.
pub fn block_ending_at(delta: &[String], end: u64) -> Option<usize> {
    let first_id = |b: &String| -> Option<u64> { b.split_once('+')?.0.parse().ok() };
    let next = delta
        .iter()
        .position(|b| first_id(b).is_some_and(|id| id >= end))?;
    next.checked_sub(1)
}
