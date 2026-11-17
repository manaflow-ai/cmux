//! Every Chief action has one of three lifetimes (Leo, 2026-11-10: "when I tell it to organize my
//! workspace versus groups, you don't need to make a workspace for that ... Things eventually just
//! expire. Do you need to keep track of the ongoing things? Sometimes you do if they're still
//! running, but if they're not running, how often do you really need to keep prodding them?"):
//!
//! - [`Lifetime::Direct`]: one tool call that changes app state (organize, group, rename, move,
//!   hide). The Chief does it in its own turn with the cmux workspace tools; it never makes a
//!   workspace or a helper, so `spawn` refuses such a task.
//! - [`Lifetime::Task`]: a helper that runs in the background with no workspace: a row in the
//!   composer hat while it runs, a one-line result when it ends, then it expires from the hat
//!   (the chat keeps it).
//! - [`Lifetime::Workspace`]: only for something to watch or touch (an agent the person steers,
//!   a terminal, a browser, a running app). It is [`Visibility::Shown`] when the person named it,
//!   when it needs their input, or when it should run past [`LONG_RUN`]; otherwise it is
//!   [`Visibility::Tucked`] into the collapsed [`TUCK_GROUP`] group and closes when its work ends.
//!
//! [`route`] decides, in this order: an organize request is always Direct; then a preference the
//! person told the Chief to remember (`## Learned` in `person.md`, `remember.rs`); then the
//! Chief's own `Sidebar:` choice; then the words of the task (`sidebar_choice` rules). The
//! person's sticky choice for a kind of work is a learned line too ("tuck review work away",
//! "show me design work"), so it holds in every later host start. Pure: the spawner hands
//! it the task, the learned lines and the rules.
//!
//! Each Chief-made subagent carries a [`Made`] record (creator, lifetime, expiry), so one reaper
//! ([`reap_due`]) closes what has expired. Only running ones are watched (sub_watch.rs: a stall is
//! noted once per run); a finished one is never checked again.

use std::time::Duration;

use serde::{Deserialize, Serialize};

use crate::sidebar_choice::{Mode, Requested, Rules};

/// The sidebar group a tucked workspace joins, made collapsed when the sidebar has none.
pub const TUCK_GROUP: &str = "Chief";
/// A Workspace expected to run longer than this shows.
pub const LONG_RUN: Duration = Duration::from_secs(10 * 60);
/// How long a finished Task stays in the hat before it expires (the chat keeps it).
pub const HAT_TTL: Duration = Duration::from_secs(10 * 60);
/// Who made a [`Made`] record.
pub const CREATOR: &str = "chief";

/// How long a Chief action lives.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Lifetime {
    Direct,
    Task,
    Workspace,
}

impl Lifetime {
    pub fn as_str(self) -> &'static str {
        match self {
            Lifetime::Direct => "direct",
            Lifetime::Task => "task",
            Lifetime::Workspace => "workspace",
        }
    }
}

/// Where a Workspace sits in the sidebar.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Visibility {
    /// Ungrouped (or in the group its task names), in view.
    Shown,
    /// In the collapsed [`TUCK_GROUP`] group; it closes when its work ends.
    Tucked,
}

/// The decision for one task, with the reason the spawn answer gives.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Route {
    pub lifetime: Lifetime,
    /// Some for a Workspace only.
    pub visibility: Option<Visibility>,
    pub why: String,
}

impl Route {
    /// This route as a shown Workspace (`why`), for a subagent only its own tab can serve.
    pub fn shown(self, why: &str) -> Route {
        Route::workspace(Visibility::Shown, why.to_owned())
    }

    fn direct(why: String) -> Route {
        Route {
            lifetime: Lifetime::Direct,
            visibility: None,
            why,
        }
    }
    fn task(why: String) -> Route {
        Route {
            lifetime: Lifetime::Task,
            visibility: None,
            why,
        }
    }
    fn workspace(visibility: Visibility, why: String) -> Route {
        Route {
            lifetime: Lifetime::Workspace,
            visibility: Some(visibility),
            why,
        }
    }
}

/// What every Chief-made subagent carries, so one reaper cleans up after it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Made {
    /// Always [`CREATOR`].
    pub creator: String,
    pub lifetime: Lifetime,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub visibility: Option<Visibility>,
    /// When it expires (ms since the epoch): set when its work ends. A tucked workspace closes
    /// then; a Task leaves the hat. None while it runs, and for a shown workspace, which the
    /// person closes.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expires_ms: Option<u64>,
}

impl Made {
    pub fn of(route: &Route) -> Made {
        Made {
            creator: CREATOR.to_owned(),
            lifetime: route.lifetime,
            visibility: route.visibility,
            expires_ms: None,
        }
    }

    pub fn tucked(&self) -> bool {
        self.visibility == Some(Visibility::Tucked)
    }

    /// Sets the expiry when its work ends at `now_ms`: a tucked workspace at once, a Task after
    /// [`HAT_TTL`]; a shown workspace never.
    pub fn ended(&mut self, now_ms: u64) {
        self.expires_ms = match (self.lifetime, self.visibility) {
            (Lifetime::Workspace, Some(Visibility::Tucked)) => Some(now_ms),
            (Lifetime::Task, _) => Some(now_ms + HAT_TTL.as_millis() as u64),
            _ => None,
        };
    }
}

/// Whether the reaper closes the workspace of a subagent that carries `made` at `now_ms`: a
/// tucked one whose work has ended.
pub fn reap_due(made: Option<&Made>, has_workspace: bool, now_ms: u64) -> bool {
    has_workspace && made.is_some_and(|m| m.tucked() && m.expires_ms.is_some_and(|at| at <= now_ms))
}

/// Verbs of an organize request.
const ORGANIZE_VERBS: &[&str] = &[
    "organize",
    "organise",
    "reorganize",
    "reorganise",
    "group",
    "regroup",
    "ungroup",
    "sort",
    "tidy",
    "rename",
    "reorder",
    "arrange",
    "rearrange",
    "move",
    "pin",
    "unpin",
    "hide",
    "collapse",
    "expand",
    "declutter",
    "archive",
];
/// What an organize request acts on: the app's own things, named anywhere.
const ORGANIZE_OBJECTS: &[&str] = &["workspace", "workspaces", "sidebar"];
/// Things an organize request acts on only when the person points at theirs ("group the tabs",
/// "sort my panes"), so "how Arc and Chrome group tabs" or "the customer groups" is not one.
const ORGANIZE_OWNED: &[&str] = &[
    "my groups",
    "the groups",
    "my tabs",
    "the tabs",
    "these tabs",
    "all tabs",
    "my panes",
    "the panes",
    "these panes",
];
/// Words that make a task code work even when it names the sidebar ("move the sidebar code").
const CODE_WORDS: &[&str] = &[
    "code",
    "implement",
    "fix",
    "bug",
    "refactor",
    "pr",
    "pull request",
    "commit",
    "test",
    "tests",
    "build",
    "crate",
    "function",
    "component",
    "css",
    "swift",
    "rust",
    "typescript",
];
/// Words of something to watch or touch.
const WATCH_WORDS: &[&str] = &[
    "terminal",
    "browser",
    "dev server",
    "simulator",
    "run the app",
    "running app",
    "steer",
    "pair",
    "jump in",
    "take over",
    "watch it",
    "watch along",
    "follow along",
    "interactive",
];

/// The topic words a learned line is about: its words without these.
const PREFERENCE_WORDS: &[&str] = &[
    "a",
    "an",
    "the",
    "for",
    "to",
    "it",
    "its",
    "me",
    "my",
    "i",
    "you",
    "your",
    "just",
    "do",
    "don't",
    "dont",
    "never",
    "always",
    "no",
    "not",
    "need",
    "make",
    "use",
    "and",
    "or",
    "of",
    "in",
    "on",
    "with",
    "that",
    "this",
    "things",
    "stuff",
    "when",
    "please",
    "directly",
    "yourself",
    "helper",
    "helpers",
    "workspace",
    "workspaces",
    "background",
    "show",
    "let",
    "watch",
    "keep",
    "visible",
    "sidebar",
    "spawn",
    "subagent",
    "subagents",
    "agent",
    "agents",
    "without",
    "instead",
    "learned",
    "them",
    "these",
    "those",
    "be",
    "is",
    "should",
    "can",
    "work",
    "tuck",
    "tucked",
    "away",
    "collapsed",
    "out",
    "before",
    "after",
    "done",
    "first",
    "then",
    "from",
    "into",
    "about",
    "every",
    "each",
    "what",
];

/// Words that make a learned line about routing (which lifetime a kind of work gets). Only
/// such a line routes: "always test it yourself before saying done" or "show me the diff before
/// you push" are about the work, and never refuse or show a helper.
const ROUTING_WORDS: &[&str] = &[
    "workspace",
    "workspaces",
    "helper",
    "helpers",
    "subagent",
    "subagents",
    "agent",
    "agents",
    "sidebar",
    "spawn",
    "tuck",
    "tucked",
    "in the background",
];

/// What a learned line asks for: a lifetime, and for a Workspace where it sits.
fn preference_intent(line: &str) -> Option<(Lifetime, Option<Visibility>)> {
    let has = |w: &str| crate::sidebar_choice::mentions(line, w);
    if [
        "directly",
        "yourself",
        "no helper",
        "without a helper",
        "don't spawn",
        "never spawn",
    ]
    .iter()
    .any(|w| has(w))
    {
        return Some((Lifetime::Direct, None));
    }
    if [
        "in the background",
        "no workspace",
        "don't need a workspace",
        "don't make a workspace",
        "never make a workspace",
        "without a workspace",
    ]
    .iter()
    .any(|w| has(w))
    {
        return Some((Lifetime::Task, None));
    }
    if ["tuck", "tucked", "out of the way", "collapsed"]
        .iter()
        .any(|w| has(w))
    {
        return Some((Lifetime::Workspace, Some(Visibility::Tucked)));
    }
    if [
        "show me",
        "let me watch",
        "keep it visible",
        "in the sidebar",
    ]
    .iter()
    .any(|w| has(w))
    {
        return Some((Lifetime::Workspace, Some(Visibility::Shown)));
    }
    None
}

/// The first learned line (`- TEXT (learned DATE)`) that speaks to `text` (lowercase): its
/// intent and the line. A line speaks to a task when the task names one of its topic words.
fn learned_for<'a>(
    text: &str,
    learned: &'a [String],
) -> Option<((Lifetime, Option<Visibility>), &'a str)> {
    learned.iter().find_map(|raw| {
        let line = raw.trim().trim_start_matches(['-', '*']).trim();
        let line = match line.rfind(" (learned ") {
            Some(at) if line.ends_with(')') => &line[..at],
            _ => line,
        };
        let lower = line.to_lowercase();
        if !ROUTING_WORDS
            .iter()
            .any(|w| crate::sidebar_choice::mentions(&lower, w))
        {
            return None;
        }
        let intent = preference_intent(&lower)?;
        let topic = lower
            .split(|c: char| !(c.is_alphanumeric() || c == '\''))
            .filter(|w| w.len() >= 4 && !PREFERENCE_WORDS.contains(w));
        let stem = |w: &str| w.trim_end_matches('s').trim_end_matches("ing").to_owned();
        let matches = topic.into_iter().any(|w| {
            crate::sidebar_choice::mentions(text, w)
                || crate::sidebar_choice::mentions(text, &stem(w))
        });
        matches.then_some((intent, line))
    })
}

/// Whether lowercase `text` is a request to organize the app: an organize verb, a thing it acts
/// on, and no code work.
pub fn is_organize(text: &str) -> bool {
    let has = |w: &&str| crate::sidebar_choice::mentions(text, w);
    ORGANIZE_VERBS.iter().any(has)
        && (ORGANIZE_OBJECTS.iter().any(has) || ORGANIZE_OWNED.iter().any(has))
        && !CODE_WORDS.iter().any(has)
}

/// The task's expected run in minutes from its `Expect:` header (`Expect: 30m`, `Expect: 2h`).
fn expected(task: &str) -> Option<Duration> {
    let v = crate::workspaces::header(task, "expect")?.to_lowercase();
    let v = v.split_whitespace().next()?;
    let (n, unit) = v.split_at(v.find(|c: char| !c.is_ascii_digit()).unwrap_or(v.len()));
    let n: u64 = n.parse().ok()?;
    match unit.trim_start_matches(' ') {
        "" | "m" | "min" | "mins" | "minutes" => Some(Duration::from_secs(n * 60)),
        "h" | "hr" | "hrs" | "hour" | "hours" => Some(Duration::from_secs(n * 3600)),
        "s" | "sec" | "secs" => Some(Duration::from_secs(n)),
        _ => None,
    }
}

/// The lifetime of spawn task `task` (with `requested`, its `Sidebar:` choice), after the
/// person's `learned` profile lines and the sidebar `rules`.
pub fn route(task: &str, requested: Requested, learned: &[String], rules: &Rules) -> Route {
    let body = crate::sidebar_choice::body(task);
    let text = body.to_lowercase();
    if is_organize(&text) {
        return Route::direct(
            "an organize request is one direct change: do it yourself, no helper or workspace"
                .into(),
        );
    }
    if let Some((intent, line)) = learned_for(&text, learned) {
        let why = format!("you told me: \"{line}\"");
        return match intent {
            (Lifetime::Direct, _) => Route::direct(why),
            (Lifetime::Task, _) => Route::task(why),
            (Lifetime::Workspace, visibility) => {
                Route::workspace(visibility.unwrap_or(Visibility::Shown), why)
            }
        };
    }
    // The person's mode (and the old show-all setting) wins over the Chief's own choice.
    match rules.mode {
        Mode::Always => {
            return Route::workspace(
                Visibility::Shown,
                format!("the setting {} is always", crate::sidebar_choice::MODE_KEY),
            );
        }
        Mode::Never => {
            return Route::task(format!(
                "the setting {} is never",
                crate::sidebar_choice::MODE_KEY
            ));
        }
        Mode::Auto if rules.legacy_show_all => {
            let choice = crate::sidebar_choice::decide(task, requested, rules);
            return Route::workspace(Visibility::Shown, choice.why);
        }
        Mode::Auto => {}
    }
    match requested {
        Requested::Shown => {
            return Route::workspace(Visibility::Shown, "you asked for sidebar: shown".into());
        }
        Requested::Hidden => return Route::task("you asked for sidebar: hidden".into()),
        Requested::Auto => {}
    }
    // The person's sidebar rules: their mode, the old show-all setting, the show and hide words
    // and the length rule.
    let choice = crate::sidebar_choice::decide(task, Requested::Auto, rules);
    let long = expected(task).is_some_and(|d| d > LONG_RUN);
    let watch = WATCH_WORDS
        .iter()
        .find(|w| crate::sidebar_choice::mentions(&text, w));
    if choice.show || long {
        let why = if long && !choice.show {
            format!("it should run past {} min", LONG_RUN.as_secs() / 60)
        } else {
            choice.why
        };
        return Route::workspace(Visibility::Shown, why);
    }
    if let Some(w) = watch {
        return Route::workspace(
            Visibility::Tucked,
            format!("auto: \"{w}\" is something to watch, but it is short, so it is tucked"),
        );
    }
    Route::task(choice.why)
}

/// The `## Learned` lines of profile text `person` (`remember.rs`).
pub fn learned_lines(person: &str) -> Vec<String> {
    let mut inside = false;
    let mut out = Vec::new();
    for line in person.lines() {
        if line.starts_with("## ") {
            inside = line.trim() == crate::remember::LEARNED_HEADING;
            continue;
        }
        if inside && line.trim_start().starts_with('-') {
            out.push(line.trim().to_owned());
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn auto(task: &str) -> Route {
        route(task, Requested::of_task(task), &[], &Rules::default())
    }

    #[test]
    fn organize_and_group_requests_are_always_direct() {
        for ask in [
            "Organize my workspaces into groups",
            "Title: Tidy\nGroup the sidebar workspaces by repo",
            "rename the workspace to Billing",
            "move these workspaces into the Infra group",
            "Hide the finished workspaces",
            "Sidebar: shown\nSort my sidebar groups",
        ] {
            let r = auto(ask);
            assert_eq!(r.lifetime, Lifetime::Direct, "{ask}: {r:?}");
            assert_eq!(r.visibility, None);
        }
        // Even under the person's show-everything mode.
        let always = Rules::from_user(Some(&json!({"chief.subagentSidebar": "always"})), true);
        let r = route("organize my workspaces", Requested::Shown, &[], &always);
        assert_eq!(r.lifetime, Lifetime::Direct);
    }

    #[test]
    fn code_work_on_the_sidebar_is_not_an_organize_request() {
        assert_ne!(
            auto("Move the sidebar code into its own crate").lifetime,
            Lifetime::Direct
        );
        assert_ne!(
            auto("Fix the bug where groups collapse in the sidebar").lifetime,
            Lifetime::Direct
        );
        assert_ne!(auto("sort the CSV by date").lifetime, Lifetime::Direct);
    }

    #[test]
    fn short_errands_are_background_tasks_and_big_or_input_work_shows() {
        let r = auto("Title: PR check\nlook up the sha of the last nightly");
        assert_eq!(r.lifetime, Lifetime::Task, "{r:?}");
        let r = auto("Make 5 design variants of the hat");
        assert_eq!(
            (r.lifetime, r.visibility),
            (Lifetime::Workspace, Some(Visibility::Shown))
        );
        let big = format!("Title: Rework\nRework the importer. {}", "word ".repeat(60));
        assert_eq!(auto(&big).visibility, Some(Visibility::Shown));
        let r = auto("Expect: 45m\nrun the soak test");
        assert_eq!(r.visibility, Some(Visibility::Shown), "{r:?}");
        assert!(r.why.contains("10 min"), "{r:?}");
        assert_eq!(auto("Expect: 5m\nsay hi").lifetime, Lifetime::Task);
    }

    #[test]
    fn something_short_to_watch_is_a_tucked_workspace() {
        let r = auto("open a terminal and tail the server log");
        assert_eq!(
            (r.lifetime, r.visibility),
            (Lifetime::Workspace, Some(Visibility::Tucked)),
            "{r:?}"
        );
        let r = auto("start the dev server");
        assert_eq!(r.visibility, Some(Visibility::Tucked));
        // Named by the person: shown.
        let r = route(
            "start the dev server",
            Requested::Shown,
            &[],
            &Rules::default(),
        );
        assert_eq!(r.visibility, Some(Visibility::Shown));
    }

    #[test]
    fn a_remembered_preference_is_checked_before_the_rules() {
        let learned = vec![
            "- Just look up release notes directly, no helper (learned 2026-11-10)".to_owned(),
            "- Run benchmarks in the background, no workspace (learned 2026-11-10)".to_owned(),
            "- Show me screenshots work in the sidebar (learned 2026-11-10)".to_owned(),
        ];
        let go = |t: &str| route(t, Requested::Auto, &learned, &Rules::default());
        let r = go("look up the release notes for 0.63");
        assert_eq!(r.lifetime, Lifetime::Direct, "{r:?}");
        assert!(r.why.contains("you told me"), "{r:?}");
        let big = format!("Run the benchmark suite. {}", "word ".repeat(60));
        assert_eq!(go(&big).lifetime, Lifetime::Task);
        assert_eq!(
            go("take screenshots of Home").visibility,
            Some(Visibility::Shown)
        );
        // A line about something else does not apply.
        assert_eq!(
            go("open a terminal and tail the log").visibility,
            Some(Visibility::Tucked)
        );
        // A preference never turns an organize request into a helper.
        let learned = vec!["- Show me workspace organizing in the sidebar".to_owned()];
        let r = route(
            "organize my workspaces",
            Requested::Auto,
            &learned,
            &Rules::default(),
        );
        assert_eq!(r.lifetime, Lifetime::Direct);
    }

    #[test]
    fn a_learned_line_about_the_work_itself_never_routes() {
        // Review of #40148: everyday lines with "yourself" or "show me" refused coding tasks.
        let learned = vec![
            "- Always test it yourself before saying done (learned 2026-11-05)".to_owned(),
            "- Show me the diff before you push (learned 2026-11-05)".to_owned(),
        ];
        let never = Rules::from_user(Some(&json!({"chief.subagentSidebar": "never"})), true);
        for (rules, want) in [(&Rules::default(), None), (&never, None)] {
            let r = route(
                "Title: Fix login\nFix the login bug and check it works before you're done; push the diff",
                Requested::Auto,
                &learned,
                rules,
            );
            assert_eq!(r.lifetime, Lifetime::Task, "{r:?}");
            assert_eq!(r.visibility, want, "{r:?}");
            assert!(!r.why.contains("you told me"), "{r:?}");
        }
    }

    #[test]
    fn a_routing_word_is_never_a_topic_word() {
        // Re-review of #40148: "agents" in a routing line matched every task about agents.
        let learned = vec![
            "- Don't spawn agents for quick lookups, do it yourself (learned 2026-11-10)"
                .to_owned(),
        ];
        let go = |t: &str| route(t, Requested::Auto, &learned, &Rules::default());
        let r = go("Title: Agent chat scroll\nFix the agent chat scroll bug");
        assert_ne!(r.lifetime, Lifetime::Direct, "{r:?}");
        let r = go("a quick lookup of the release date");
        assert_eq!(r.lifetime, Lifetime::Direct, "{r:?}");
    }

    #[test]
    fn writing_about_tabs_or_groups_is_not_an_organize_request() {
        for ask in [
            "Write a doc comparing how Arc and Chrome group tabs",
            "sort the customer groups by revenue",
        ] {
            assert_ne!(auto(ask).lifetime, Lifetime::Direct, "{ask}");
        }
        assert_eq!(auto("group the tabs by site").lifetime, Lifetime::Direct);
    }

    #[test]
    fn the_persons_learned_choice_for_a_kind_of_work_tucks_or_shows_it() {
        let learned = vec![
            "- Tuck review work out of the way (learned 2026-11-10)".to_owned(),
            "- Show me design work in the sidebar (learned 2026-11-10)".to_owned(),
        ];
        let go = |t: &str| route(t, Requested::Auto, &learned, &Rules::default());
        assert_eq!(
            go("review the importer diff").visibility,
            Some(Visibility::Tucked)
        );
        assert_eq!(
            go("a design pass on the hat").visibility,
            Some(Visibility::Shown)
        );
        // The Chief's explicit choice (the person named it) does not beat what they told it.
        let r = route("review it", Requested::Hidden, &learned, &Rules::default());
        assert_eq!(r.visibility, Some(Visibility::Tucked));
    }

    #[test]
    fn one_reaper_closes_a_tucked_workspace_when_its_work_ends_and_nothing_else() {
        let tucked = Made::of(&auto("open a terminal and tail the log"));
        assert_eq!(tucked.creator, CREATOR);
        assert!(!reap_due(Some(&tucked), true, 1_000), "still running");
        let mut ended = tucked.clone();
        ended.ended(1_000);
        assert!(reap_due(Some(&ended), true, 1_000));
        assert!(!reap_due(Some(&ended), false, 1_000), "already closed");
        let mut shown = Made::of(&auto("Make 5 design variants"));
        shown.ended(1_000);
        assert_eq!(shown.expires_ms, None);
        assert!(!reap_due(Some(&shown), true, u64::MAX));
        let mut task = Made::of(&auto("look up a sha"));
        task.ended(1_000);
        assert_eq!(task.expires_ms, Some(1_000 + HAT_TTL.as_millis() as u64));
        assert!(!reap_due(Some(&task), false, u64::MAX));
        assert!(
            !reap_due(None, true, u64::MAX),
            "an older record is never reaped"
        );
        let wire = serde_json::to_value(&ended).unwrap();
        assert_eq!(
            wire,
            json!({"creator": "chief", "lifetime": "workspace", "visibility": "tucked", "expires_ms": 1000})
        );
    }

    #[test]
    fn a_subagent_that_asks_before_it_acts_is_shown_never_tucked_or_reaped() {
        let r = auto("open a terminal and tail the log").shown("it asks before it acts");
        let mut made = Made::of(&r);
        assert_eq!(made.visibility, Some(Visibility::Shown));
        made.ended(1_000);
        assert!(!reap_due(Some(&made), true, u64::MAX));
    }

    #[test]
    fn learned_lines_come_from_the_learned_section_only() {
        let person = "# Leo\n- not this\n## Learned\n- Organize directly (learned 2026-11-10)\n## Other\n- nor this\n";
        assert_eq!(
            learned_lines(person),
            vec!["- Organize directly (learned 2026-11-10)"]
        );
    }
}
