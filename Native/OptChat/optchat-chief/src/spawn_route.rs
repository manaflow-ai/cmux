//! The automatic harness picker for `spawn`: with subagent routing on (off by
//! default: `chief engine set --subagent-routing auto` or cmux.json
//! `chief.autoRouteSubagents`) and a spawn that names no harness or model,
//! each task goes to the harness its kind fits.
//!
//! Leo, 2026-10-31: "if you look into grokbot they auto route stuff all the
//! time", "we wanna be at least as good as grokbot"; 2026-11-01: "optional
//! ofc we don't wanna change defaults or whatnot yet". Grok Bot routes each
//! request by what it is (small fast models for simple asks, large ones for
//! hard ones); the community grok-build-auto-route splits subagents into
//! read/search, edit/test and architecture/review tiers. This picker does the
//! same by kind, over the harnesses acpmux has and the person's grant allows,
//! and follows the team's split (Claude oversees, Codex does the bulk coding,
//! a review is by the other model):
//!
//! - code (implement, fix, refactor, tests, CI, a PR): a Codex harness
//! - writing (docs, design, research, plans, UI, screenshots): a Claude harness
//! - review (review, audit, a second opinion): the other family than the
//!   Chief's subagent harness, so a review is cross-model
//! - mechanical (wait, relay, status, list, grep): a Claude harness on its
//!   small model when the harness offers one (Haiku)
//!
//! A task with no clear kind, or whose pick is the default harness with no
//! model, stays on the default. Pure: the spawner hands it the harness
//! families, the grant and the offered models.

use std::collections::BTreeMap;

use crate::acpmux::Family;

/// What a task is, from its words.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TaskKind {
    Code,
    Writing,
    Review,
    Mechanical,
}

impl TaskKind {
    /// The words a spawn answer names the pick by.
    pub fn reason(self) -> &'static str {
        match self {
            TaskKind::Code => "code task",
            TaskKind::Writing => "writing, design or research task",
            TaskKind::Review => "review: the other model",
            TaskKind::Mechanical => "mechanical task: a small model",
        }
    }
}

/// One task's pick: the harness, a model when the kind takes one, and why.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Pick {
    pub harness: String,
    pub model: Option<String>,
    pub kind: TaskKind,
}

const CODE: &[&str] = &[
    "implement", "implementation", "fix", "fixes", "bug", "bugs", "refactor", "build", "compile",
    "test", "tests", "ci", "pr", "prs", "patch", "migrate", "migration", "port", "rust",
    "swift", "typescript", "cargo", "crash", "regression", "lint", "clippy", "function",
    "endpoint", "code", "coding", "rebase", "merge", "commit",
];
const WRITING: &[&str] = &[
    "write", "doc", "docs", "documentation", "design", "spec", "research", "summarize",
    "summary", "explain", "plan", "draft", "copy", "ui", "screenshot", "screenshots",
    "mockup", "gallery", "browser", "report", "brief", "investigate", "compare",
];
const REVIEW: &[&str] = &["review", "reviews", "audit", "critique"];
const MECHANICAL: &[&str] = &[
    "wait", "relay", "status", "list", "grep", "poll", "count", "lookup", "ping", "tally",
];

fn score(words: &[String], list: &[&str]) -> usize {
    words.iter().filter(|w| list.contains(&w.as_str())).count()
}

/// The task's kind, or None when its words do not say.
pub fn classify(task: &str) -> Option<TaskKind> {
    let lower = task.to_lowercase();
    let words: Vec<String> = lower
        .split(|c: char| !c.is_alphanumeric())
        .filter(|w| !w.is_empty())
        .map(str::to_owned)
        .collect();
    let review = score(&words, REVIEW) + usize::from(lower.contains("second opinion"));
    let code = score(&words, CODE);
    let writing = score(&words, WRITING);
    let mechanical = score(&words, MECHANICAL) + usize::from(lower.contains("look up"));
    if review > 0 && review >= code {
        return Some(TaskKind::Review);
    }
    if code > writing {
        return Some(TaskKind::Code);
    }
    if writing > code {
        return Some(TaskKind::Writing);
    }
    if code == 0 && writing == 0 && mechanical > 0 {
        return Some(TaskKind::Mechanical);
    }
    None
}

/// The harness of `family` for a pick: `default` when it is of that family,
/// else the profile named after the family (`codex`, `claude`), else the
/// first allowed one by name; None when acpmux has none the grant allows.
fn harness_of(
    family: Family,
    default: &str,
    families: &BTreeMap<String, Family>,
    allowed: &dyn Fn(&str) -> bool,
) -> Option<String> {
    if families.get(default) == Some(&family) && allowed(default) {
        return Some(default.to_owned());
    }
    let mut of: Vec<&String> = families
        .iter()
        .filter(|(h, f)| **f == family && allowed(h))
        .map(|(h, _)| h)
        .collect();
    of.sort();
    let named = match family {
        Family::Claude => "claude",
        Family::Codex => "codex",
        Family::Other => "",
    };
    of.iter()
        .find(|h| h.as_str() == named)
        .or_else(|| of.first())
        .map(|h| (*h).clone())
}

/// `task`'s pick against `default` (the subagent harness a spawn that names
/// none runs on): None when its kind is unclear, no harness fits, or the pick
/// is `default` with no model (nothing to route). `offered` lists a harness's
/// model ids (acpmux's catalog).
pub fn pick(
    task: &str,
    default: &str,
    families: &BTreeMap<String, Family>,
    allowed: &dyn Fn(&str) -> bool,
    offered: &dyn Fn(&str) -> Vec<String>,
) -> Option<Pick> {
    let kind = classify(task)?;
    let default_family = families.get(default).copied().unwrap_or(Family::Claude);
    let family = match kind {
        TaskKind::Code => Family::Codex,
        TaskKind::Writing | TaskKind::Mechanical => Family::Claude,
        TaskKind::Review => match default_family {
            Family::Codex => Family::Claude,
            _ => Family::Codex,
        },
    };
    let harness = harness_of(family, default, families, allowed)?;
    let model = if kind == TaskKind::Mechanical {
        offered(&harness)
            .into_iter()
            .find(|m| m.starts_with("claude-haiku"))
    } else {
        None
    };
    if harness == default && model.is_none() {
        return None;
    }
    Some(Pick {
        harness,
        model,
        kind,
    })
}
