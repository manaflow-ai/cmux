//! Every Chief action has one of two lifetimes, and no subagent is ever hidden (Aziz, relayed
//! 2026-11-11: "Chief-made agents getting hidden quite often - cant find them in sidebar despite
//! me telling it to always show agents in sidebar ... make chief can only make 2 types of
//! workspaces, no hidden workspaces at all"):
//!
//! - [`Lifetime::Direct`]: one tool call that changes app state (organize, group, rename, move).
//!   The Chief does it in its own turn with the cmux workspace tools; `spawn` refuses such a task.
//! - [`Lifetime::Workspace`]: every subagent. Its workspace is one of two kinds:
//!   [`Visibility::User`], a normal sidebar workspace (ungrouped, at the top below the pinned
//!   rows) for work the person watches, joins or steers, UI and design, long builds, anything that
//!   needs their input; or [`Visibility::Chief`], a workspace in the collapsed [`CHIEF_GROUP`]
//!   group for lookups, status checks, land-queue followers and cleanups. The group is still
//!   listed and searchable, so the person always finds it; nothing closes it on its own.
//!
//! [`route`] decides, in this order: an organize request is always Direct; then a preference the
//! person told the Chief to remember (`## Learned` in `person.md`, `remember.rs`: "always show
//! agents in the sidebar" makes every subagent a User workspace); then the person's
//! `chief.subagentSidebar` setting; then the Chief's own `Sidebar:` choice; then the words of the
//! task (`sidebar_choice` rules). Pure: the spawner hands it the task, the learned lines and the
//! rules.
//!
//! Each Chief-made subagent carries a [`Made`] record (creator, lifetime, kind). Only running ones
//! are watched (sub_watch.rs: a stall is noted once per run); a finished one is never checked
//! again.

use std::time::Duration;

use serde::{Deserialize, Serialize};

use crate::sidebar_choice::{Mode, Requested, Rules};

/// The sidebar group of a [`Visibility::Chief`] workspace, made collapsed when the sidebar has
/// none.
pub const CHIEF_GROUP: &str = crate::workspaces::CHIEF_GROUP_NAME;
/// A subagent expected to run longer than this is a [`Visibility::User`] workspace.
pub const LONG_RUN: Duration = Duration::from_secs(10 * 60);
/// How long a finished older background Task record stays in the hat (records made before every
/// subagent got a workspace; none is routed there now).
pub const HAT_TTL: Duration = Duration::from_secs(10 * 60);
/// Who made a [`Made`] record.
pub const CREATOR: &str = "chief";

/// How long a Chief action lives.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Lifetime {
    Direct,
    /// Read from records saved before 2026-11-11 only: [`route`] never answers it.
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

/// Which of the two kinds a subagent's workspace is.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Visibility {
    /// A normal sidebar workspace, ungrouped (or in the group its task names), at the top.
    #[serde(alias = "shown")]
    User,
    /// In the collapsed [`CHIEF_GROUP`] group: listed and searchable, never closed on its own.
    #[serde(alias = "tucked")]
    Chief,
}

impl Visibility {
    pub fn as_str(self) -> &'static str {
        match self {
            Visibility::User => "user",
            Visibility::Chief => "chief",
        }
    }
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
    /// This route as a User workspace (`why`), for a subagent only its own tab can serve.
    pub fn shown(self, why: &str) -> Route {
        Route::workspace(Visibility::User, why.to_owned())
    }

    /// Whether this route puts the subagent in the [`CHIEF_GROUP`] group.
    pub fn in_chief_group(&self) -> bool {
        self.visibility == Some(Visibility::Chief)
    }

    fn direct(why: String) -> Route {
        Route {
            lifetime: Lifetime::Direct,
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

/// What every Chief-made subagent carries.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Made {
    /// Always [`CREATOR`].
    pub creator: String,
    pub lifetime: Lifetime,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub visibility: Option<Visibility>,
    /// When an older background Task record leaves the hat (ms since the epoch). A workspace
    /// never expires: the person closes it.
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

    /// Whether its workspace sits in the [`CHIEF_GROUP`] group.
    pub fn in_chief_group(&self) -> bool {
        self.visibility == Some(Visibility::Chief)
    }

    /// Sets the expiry when its work ends at `now_ms`: an older Task record after [`HAT_TTL`]; a
    /// workspace never.
    pub fn ended(&mut self, now_ms: u64) {
        self.expires_ms = match self.lifetime {
            Lifetime::Task => Some(now_ms + HAT_TTL.as_millis() as u64),
            _ => None,
        };
    }
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

/// What a learned line asks for: a lifetime, and for a Workspace which kind.
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
    // Before every subagent got a workspace, "in the background" and "no workspace" meant none;
    // the nearest kind now is the Chief's own group.
    if [
        "in the background",
        "no workspace",
        "don't need a workspace",
        "don't make a workspace",
        "never make a workspace",
        "without a workspace",
        "tuck",
        "tucked",
        "out of the way",
        "collapsed",
        "chief's workspaces",
        "chief's group",
    ]
    .iter()
    .any(|w| has(w))
    {
        return Some((Lifetime::Workspace, Some(Visibility::Chief)));
    }
    if [
        "show me",
        "let me watch",
        "keep it visible",
        "in the sidebar",
        "in sidebar",
        "always show",
        "show agents",
        "show subagents",
        "show every",
        "show all",
        "visible",
    ]
    .iter()
    .any(|w| has(w))
    {
        return Some((Lifetime::Workspace, Some(Visibility::User)));
    }
    None
}

/// The first learned line (`- TEXT (learned DATE)`) that speaks to `text` (lowercase): its
/// intent and the line. A line speaks to a task when the task names one of its topic words; a
/// line with no topic word that picks a workspace kind ("always show agents in the sidebar")
/// speaks to every task.
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
        let topic: Vec<&str> = lower
            .split(|c: char| !(c.is_alphanumeric() || c == '\''))
            .filter(|w| w.len() >= 4 && !PREFERENCE_WORDS.contains(w))
            .collect();
        // A general rule about where agents go; never a general "do it yourself", which would
        // refuse every spawn.
        if topic.is_empty() {
            return (intent.0 == Lifetime::Workspace).then_some((intent, line));
        }
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
/// person's `learned` profile lines and the sidebar `rules`. Anything that is not an organize
/// request is a Workspace, of the User or the Chief kind.
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
            (_, visibility) => Route::workspace(visibility.unwrap_or(Visibility::User), why),
        };
    }
    // The person's mode (and the old show-all setting) wins over the Chief's own choice.
    let mode_why = || format!("the setting {} is", crate::sidebar_choice::MODE_KEY);
    match rules.mode {
        Mode::Always => {
            return Route::workspace(Visibility::User, format!("{} always", mode_why()));
        }
        Mode::Never => {
            return Route::workspace(Visibility::Chief, format!("{} never", mode_why()));
        }
        Mode::Auto if rules.legacy_show_all => {
            let choice = crate::sidebar_choice::decide(task, requested, rules);
            return Route::workspace(Visibility::User, choice.why);
        }
        Mode::Auto => {}
    }
    match requested {
        Requested::User => {
            return Route::workspace(Visibility::User, "you asked for sidebar: user".into());
        }
        Requested::Chief => {
            return Route::workspace(Visibility::Chief, "you asked for sidebar: chief".into());
        }
        Requested::Auto => {}
    }
    // A user word or a Chief word in the task decides first; then something the person
    // watches, joins or steers, or a long run, is theirs to see; then the task's length.
    let choice = crate::sidebar_choice::decide(task, Requested::Auto, rules);
    if choice.by == crate::sidebar_choice::By::Word {
        let kind = if choice.user {
            Visibility::User
        } else {
            Visibility::Chief
        };
        return Route::workspace(kind, choice.why);
    }
    if expected(task).is_some_and(|d| d > LONG_RUN) {
        return Route::workspace(
            Visibility::User,
            format!("auto: it should run past {} min", LONG_RUN.as_secs() / 60),
        );
    }
    if let Some(w) = WATCH_WORDS
        .iter()
        .find(|w| crate::sidebar_choice::mentions(&text, w))
    {
        return Route::workspace(
            Visibility::User,
            format!("auto: \"{w}\" is something the user watches or joins"),
        );
    }
    let kind = if choice.user {
        Visibility::User
    } else {
        Visibility::Chief
    };
    Route::workspace(kind, choice.why)
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
        let r = route("organize my workspaces", Requested::User, &[], &always);
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

    fn kind(r: &Route) -> (Lifetime, Option<Visibility>) {
        (r.lifetime, r.visibility)
    }
    const USER: (Lifetime, Option<Visibility>) = (Lifetime::Workspace, Some(Visibility::User));
    const CHIEF: (Lifetime, Option<Visibility>) = (Lifetime::Workspace, Some(Visibility::Chief));

    #[test]
    fn short_errands_go_to_the_chiefs_group_and_big_or_input_work_to_the_sidebar() {
        let r = auto("Title: PR check\nlook up the sha of the last nightly");
        assert_eq!(kind(&r), CHIEF, "{r:?}");
        assert_eq!(kind(&auto("Make 5 design variants of the hat")), USER);
        let big = format!("Title: Rework\nRework the importer. {}", "word ".repeat(60));
        assert_eq!(kind(&auto(&big)), USER);
        let r = auto("Expect: 45m\nrun the soak test");
        assert_eq!(kind(&r), USER, "{r:?}");
        assert!(r.why.contains("10 min"), "{r:?}");
        assert_eq!(kind(&auto("Expect: 5m\nsay hi")), CHIEF);
        // A land-queue follower stays in the Chief's group even when it runs long.
        let r = auto("Expect: 2h\nFollow landq entry 1234 until it lands");
        assert_eq!(kind(&r), CHIEF, "{r:?}");
    }

    #[test]
    fn something_to_watch_or_join_is_a_user_workspace() {
        assert_eq!(kind(&auto("open a terminal and tail the server log")), USER);
        assert_eq!(kind(&auto("start the dev server")), USER);
        let r = route(
            "start the dev server",
            Requested::Chief,
            &[],
            &Rules::default(),
        );
        assert_eq!(kind(&r), CHIEF, "the Chief's own choice holds");
    }

    #[test]
    fn no_route_is_without_a_workspace() {
        let never = Rules::from_user(Some(&json!({"chief.subagentSidebar": "never"})), false);
        for (task, rules) in [
            ("say hi", &Rules::default()),
            ("Sidebar: hidden\nsay hi", &Rules::default()),
            ("Make 5 design variants", &never),
        ] {
            let r = route(task, Requested::of_task(task), &[], rules);
            assert_eq!(r.lifetime, Lifetime::Workspace, "{task}: {r:?}");
            assert!(r.visibility.is_some(), "{task}: {r:?}");
        }
        assert_eq!(
            kind(&route(
                "Make 5 design variants",
                Requested::Auto,
                &[],
                &never
            )),
            CHIEF
        );
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
        assert_eq!(
            kind(&go(&big)),
            CHIEF,
            "\"no workspace\" is the Chief's group now"
        );
        assert_eq!(kind(&go("take screenshots of Home")), USER);
        assert_eq!(kind(&go("open a terminal and tail the log")), USER);
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
    fn always_show_agents_in_the_sidebar_applies_to_every_task() {
        // Aziz's rule: no topic word, so it speaks to every spawn, over the Chief's choice.
        let learned = vec!["- Always show agents in the sidebar (learned 2026-11-10)".to_owned()];
        for task in [
            "look up a sha",
            "Sidebar: chief\nFollow landq entry 9 until it lands",
            "clean up the scratch branches",
        ] {
            let r = route(task, Requested::of_task(task), &learned, &Rules::default());
            assert_eq!(kind(&r), USER, "{task}: {r:?}");
            assert!(r.why.contains("you told me"), "{r:?}");
        }
        // A general "do it yourself" line never refuses every spawn.
        let learned = vec!["- Don't spawn agents, do it yourself".to_owned()];
        let r = route(
            "fix the crash",
            Requested::Auto,
            &learned,
            &Rules::default(),
        );
        assert_ne!(r.lifetime, Lifetime::Direct, "{r:?}");
    }

    #[test]
    fn a_learned_line_about_the_work_itself_never_routes() {
        let learned = vec![
            "- Always test it yourself before saying done (learned 2026-11-05)".to_owned(),
            "- Show me the diff before you push (learned 2026-11-05)".to_owned(),
        ];
        let never = Rules::from_user(Some(&json!({"chief.subagentSidebar": "never"})), true);
        for rules in [&Rules::default(), &never] {
            let r = route(
                "Title: Fix login\nFix the login bug and check it works before you're done; push the diff",
                Requested::Auto,
                &learned,
                rules,
            );
            assert_eq!(kind(&r), CHIEF, "{r:?}");
            assert!(!r.why.contains("you told me"), "{r:?}");
        }
    }

    #[test]
    fn a_routing_word_is_never_a_topic_word() {
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
    fn the_persons_learned_choice_for_a_kind_of_work_picks_its_kind() {
        let learned = vec![
            "- Tuck review work out of the way (learned 2026-11-10)".to_owned(),
            "- Show me design work in the sidebar (learned 2026-11-10)".to_owned(),
        ];
        let go = |t: &str| route(t, Requested::Auto, &learned, &Rules::default());
        assert_eq!(kind(&go("review the importer diff")), CHIEF);
        assert_eq!(kind(&go("a design pass on the hat")), USER);
        let r = route("review it", Requested::User, &learned, &Rules::default());
        assert_eq!(kind(&r), CHIEF);
    }

    #[test]
    fn a_finished_workspace_never_expires_and_old_records_still_read() {
        let mut chief = Made::of(&auto("look up a sha"));
        assert_eq!(chief.creator, CREATOR);
        assert!(chief.in_chief_group());
        chief.ended(1_000);
        assert_eq!(chief.expires_ms, None, "nothing closes it on its own");
        let wire = serde_json::to_value(&chief).unwrap();
        assert_eq!(
            wire,
            json!({"creator": "chief", "lifetime": "workspace", "visibility": "chief"})
        );
        // Records saved before the two kinds.
        let old: Made = serde_json::from_value(
            json!({"creator": "chief", "lifetime": "workspace", "visibility": "tucked", "expires_ms": 1000}),
        )
        .unwrap();
        assert!(old.in_chief_group());
        let old: Made = serde_json::from_value(
            json!({"creator": "chief", "lifetime": "workspace", "visibility": "shown"}),
        )
        .unwrap();
        assert_eq!(old.visibility, Some(Visibility::User));
    }

    #[test]
    fn a_subagent_that_asks_before_it_acts_is_a_user_workspace() {
        let r = auto("look up a sha").shown("it asks before it acts");
        assert_eq!(kind(&r), USER);
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
