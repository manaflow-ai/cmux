//! Where a Chief subagent's workspace goes when it starts (a1018, then Lawrence
//! 2026-11-09: "Chief's default must be to NOT start new workspaces all the
//! time"). Three places ([`Place`]):
//!
//! - `user`: a workspace in the normal sidebar (top, below pinned rows), for
//!   work the user looks at or joins: UI, design and screenshot work, anything
//!   that needs the user's input or sign-in, a long build the user asked for.
//! - `internal`: a workspace in the one sidebar group "Chief's workspaces"
//!   (``crate::workspaces::CHIEF_GROUP_NAME``), made collapsed once and reused,
//!   for internal work that still needs tabs: a topic's diff and preview holder.
//! - `none`: no workspace. The subagent's chat lives in acpmux; its link in the
//!   Chief's reply opens it, and `control show` adds a workspace later.
//!
//! The Chief chooses per spawn (`spawn(workspace)`, or a `Workspace:` line in one
//! task; the older `Sidebar: shown|hidden` still reads as user|none). `auto`, the
//! default, applies [`Rules`]: a task that mentions a user-facing word goes to the
//! sidebar; any other task gets none (or `internal` under the user's `group`
//! mode). A length rule (`min_words`, off by default) can send long tasks to the
//! sidebar too.
//!
//! The user shapes the rules in cmux-next.json (Settings > Chief > Subagents), read
//! at each spawn: `chief.subagentSidebar` (`auto`, `always`, `group`, `never`;
//! a1018's values keep their meaning) overrides the Chief, `chief.subagentSidebarShowWords` and
//! `chief.subagentSidebarHideWords` add words to the built-in lists, and
//! `chief.subagentSidebarMinWords` turns on the length rule. The older Chief
//! setting `subagents.showWorkspaces` true still shows every subagent.

use serde_json::Value;

/// The cmux-next.json key of [`Mode`].
pub const MODE_KEY: &str = "chief.subagentSidebar";
/// The cmux-next.json key of the user's extra user-facing words.
pub const SHOW_WORDS_KEY: &str = "chief.subagentSidebarShowWords";
/// The cmux-next.json key of the user's extra internal words.
pub const HIDE_WORDS_KEY: &str = "chief.subagentSidebarHideWords";
/// The cmux-next.json key of [`Rules::min_words`].
pub const MIN_WORDS_KEY: &str = "chief.subagentSidebarMinWords";

/// The length rule's default: off. Nearly every Chief task is long, so length
/// says nothing about whether the user will look at it.
pub const DEFAULT_MIN_WORDS: usize = 0;

/// Words that make a task user-facing under `auto`: work the user looks at or
/// must act on.
pub const SHOW_WORDS: &[&str] = &[
    "ui",
    "ux",
    "design",
    "redesign",
    "visual",
    "screenshot",
    "screenshots",
    "shots",
    "before|after",
    "before/after",
    "variants",
    "variations",
    "playground",
    "prototype",
    "mockup",
    "demo",
    "needs you",
    "user's input",
    "your input",
    "sign in",
    "sign-in",
];

/// Words that mark a task internal under `auto`: errands nobody watches. They
/// win over the length rule, never over a user-facing word.
pub const HIDE_WORDS: &[&str] = &[
    "lookup",
    "look up",
    "cleanup",
    "clean up",
    "land queue",
    "landq",
    "poll",
    "follow the entry",
    "delete scratch",
    "status check",
    "read-only check",
    "summarize",
    "re-check",
    "recheck",
    "watch",
];

/// Where a subagent's workspace goes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Place {
    /// A workspace in the normal sidebar.
    User,
    /// A workspace in the collapsed "Chief's workspaces" group.
    Internal,
    /// No workspace; `control show` adds one later.
    None,
}

impl Place {
    pub fn as_str(self) -> &'static str {
        match self {
            Place::User => "user",
            Place::Internal => "internal",
            Place::None => "none",
        }
    }
}

/// What the Chief asked for one task.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Requested {
    /// This place.
    Place(Place),
    /// The rules decide.
    Auto,
}

impl Requested {
    /// `user`, `internal`, `none` or `auto` (any case); the older `shown`
    /// (`show`, `visible`) reads as user and `hidden` (`hide`) as none.
    pub fn parse(value: &str) -> Option<Requested> {
        match value.trim().to_ascii_lowercase().as_str() {
            "user" | "shown" | "show" | "visible" | "sidebar" => {
                Some(Requested::Place(Place::User))
            }
            "internal" | "group" => Some(Requested::Place(Place::Internal)),
            "none" | "hidden" | "hide" => Some(Requested::Place(Place::None)),
            "auto" => Some(Requested::Auto),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Requested::Place(p) => p.as_str(),
            Requested::Auto => "auto",
        }
    }

    /// The task's own `Workspace:` line, else its older `Sidebar:` line, else
    /// `auto`.
    pub fn of_task(task: &str) -> Requested {
        crate::workspaces::header(task, "workspace")
            .or_else(|| crate::workspaces::header(task, "sidebar"))
            .and_then(|v| Requested::parse(&v))
            .unwrap_or(Requested::Auto)
    }
}

/// The user's override (`chief.subagentSidebar`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Mode {
    /// The Chief chooses; its `auto` gives user-facing work a sidebar workspace
    /// and the rest none.
    #[default]
    Auto,
    /// Every subagent gets a sidebar workspace.
    Always,
    /// Like auto, but work that is not user-facing goes in the Chief's group
    /// instead of none.
    Group,
    /// No subagent gets a workspace (one that asks before it acts still does).
    Never,
}

/// How `auto` decides, as the user shaped it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Rules {
    pub mode: Mode,
    /// `subagents.showWorkspaces` (the Chief setting before a1018) is on.
    pub legacy_show_all: bool,
    /// Lowercase words or phrases that make a task user-facing.
    pub show_words: Vec<String>,
    /// Lowercase words or phrases that make a task internal.
    pub hide_words: Vec<String>,
    /// Task length (words) from which a task is user-facing; 0 turns the rule off.
    pub min_words: usize,
}

impl Default for Rules {
    fn default() -> Rules {
        Rules::from_user(None, false)
    }
}

impl Rules {
    /// The rules from the user's settings document (cmux-next.json) and
    /// the Chief's `subagents.showWorkspaces`; missing or invalid keys are
    /// the defaults.
    pub fn from_user(doc: Option<&Value>, legacy_show_all: bool) -> Rules {
        let get = |key: &str| doc.and_then(|d| crate::agent_memory::settings::value(d, key));
        let read = |key: &str| {
            get(key)
                .as_ref()
                .and_then(Value::as_str)
                .map(|v| v.trim().to_owned())
        };
        let mode = match read(MODE_KEY).as_deref() {
            Some("always") => Mode::Always,
            Some("group") => Mode::Group,
            Some("never") => Mode::Never,
            _ => Mode::Auto,
        };
        let words = |builtin: &[&str], key: &str| {
            let mut out: Vec<String> = builtin.iter().map(|w| (*w).to_owned()).collect();
            if let Some(Value::Array(extra)) = get(key) {
                for w in extra.iter().filter_map(Value::as_str) {
                    let w = w.trim().to_lowercase();
                    if !w.is_empty() && !out.contains(&w) {
                        out.push(w);
                    }
                }
            }
            out
        };
        Rules {
            mode,
            legacy_show_all,
            show_words: words(SHOW_WORDS, SHOW_WORDS_KEY),
            hide_words: words(HIDE_WORDS, HIDE_WORDS_KEY),
            min_words: get(MIN_WORDS_KEY)
                .as_ref()
                .and_then(Value::as_u64)
                .map(|n| n.min(10_000) as usize)
                .unwrap_or(DEFAULT_MIN_WORDS),
        }
    }

    /// Where work that is not user-facing goes: none, or the Chief's group
    /// under `group`.
    fn quiet(&self) -> Place {
        match self.mode {
            Mode::Group => Place::Internal,
            _ => Place::None,
        }
    }
}

/// The decision for one task, with the reason the spawn answer gives.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Choice {
    pub place: Place,
    pub why: String,
}

impl Choice {
    /// Whether the task gets a workspace at all.
    pub fn opens(&self) -> bool {
        self.place != Place::None
    }
}

/// Where `task` (with `requested`, the Chief's choice) gets its workspace under
/// `rules`.
pub fn decide(task: &str, requested: Requested, rules: &Rules) -> Choice {
    let choice = |place: Place, why: String| Choice { place, why };
    let key = MODE_KEY;
    match rules.mode {
        Mode::Always => return choice(Place::User, format!("the setting {key} is always")),
        Mode::Never => return choice(Place::None, format!("the setting {key} is never")),
        Mode::Auto | Mode::Group => {}
    }
    if rules.legacy_show_all {
        return choice(
            Place::User,
            format!(
                "the setting {} is on",
                crate::chief_settings::SHOW_SUBAGENT_WORKSPACES
            ),
        );
    }
    if let Requested::Place(place) = requested {
        return choice(
            place,
            format!("you asked for workspace: {}", place.as_str()),
        );
    }
    let body = body(task);
    let text = body.to_lowercase();
    if let Some(w) = rules.show_words.iter().find(|w| mentions(&text, w)) {
        return choice(
            Place::User,
            format!("auto: user-facing, the task mentions \"{w}\""),
        );
    }
    let quiet = rules.quiet();
    if let Some(w) = rules.hide_words.iter().find(|w| mentions(&text, w)) {
        return choice(quiet, format!("auto: internal, the task mentions \"{w}\""));
    }
    let n = body.split_whitespace().count();
    if rules.min_words > 0 && n >= rules.min_words {
        return choice(
            Place::User,
            format!("auto: a long task ({n} words, from {})", rules.min_words),
        );
    }
    choice(
        quiet,
        "auto: not user-facing (no UI, design, screenshot, input or sign-in word)".into(),
    )
}

/// `task` without its header lines.
fn body(task: &str) -> String {
    task.lines()
        .filter(|l| !crate::workspaces::is_header(l.trim()))
        .collect::<Vec<_>>()
        .join("\n")
}

/// Whether lowercase `text` contains `term` as whole words (no letter or
/// digit right before or after it), so "ui" never matches "build".
fn mentions(text: &str, term: &str) -> bool {
    if term.is_empty() {
        return false;
    }
    let word = |c: Option<char>| c.is_some_and(char::is_alphanumeric);
    let mut from = 0;
    while let Some(at) = text[from..].find(term) {
        let start = from + at;
        let end = start + term.len();
        if !word(text[..start].chars().next_back()) && !word(text[end..].chars().next()) {
            return true;
        }
        from = start + text[start..].chars().next().map_or(1, char::len_utf8);
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn auto(task: &str) -> Choice {
        decide(task, Requested::of_task(task), &Rules::default())
    }

    #[test]
    fn only_user_facing_work_gets_a_workspace_by_default() {
        let big = format!(
            "Title: Sidebar rework\nFix the crash. {}",
            "word ".repeat(300)
        );
        assert_eq!(auto(&big).place, Place::None, "{:?}", auto(&big));
        assert_eq!(auto("Title: PR check\nsay hello").place, Place::None);
        assert_eq!(auto("Fix the blue ring in the UI").place, Place::User);
        assert_eq!(auto("Make 5 design variants").place, Place::User);
        assert_eq!(auto("This one needs you to pick").place, Place::User);
        assert_eq!(auto("Clean up the scratch branches").place, Place::None);
        // "ui" is not "build"; a user-facing word wins over an internal one.
        assert_eq!(auto("build it").place, Place::None);
        assert_eq!(auto("Clean up the UI padding").place, Place::User);
    }

    #[test]
    fn the_chiefs_choice_wins_under_auto_and_the_users_mode_wins_over_it() {
        assert_eq!(
            auto("Workspace: internal\nTitle: Diffs\nhold diffs").place,
            Place::Internal
        );
        assert_eq!(
            auto("Sidebar: shown\nTitle: Lookup\nlook up a sha").place,
            Place::User
        );
        assert_eq!(auto("Sidebar: hidden\nRedesign the UI").place, Place::None);
        let never = Rules::from_user(Some(&json!({"chief": {"subagentSidebar": "never"}})), true);
        assert_eq!(
            decide("x", Requested::Place(Place::User), &never).place,
            Place::None
        );
        let group = Rules::from_user(Some(&json!({"chief.subagentSidebar": "group"})), false);
        assert_eq!(
            decide("look up a sha", Requested::Auto, &group).place,
            Place::Internal
        );
        assert_eq!(
            decide("fix the UI", Requested::Auto, &group).place,
            Place::User
        );
        // a1018's values keep their meaning.
        let always = Rules::from_user(Some(&json!({"chief.subagentSidebar": "always"})), false);
        let c = decide("x", Requested::Place(Place::None), &always);
        assert!(c.place == Place::User && c.why.contains(MODE_KEY), "{c:?}");
        let c = decide(
            "say hello",
            Requested::Place(Place::None),
            &Rules::from_user(None, true),
        );
        assert!(
            c.place == Place::User && c.why.contains("subagents.showWorkspaces"),
            "{c:?}"
        );
    }

    #[test]
    fn the_user_adds_words_and_turns_on_the_length_rule() {
        let doc = json!({"chief": {
            "subagentSidebarShowWords": ["Benchmark", " "],
            "subagentSidebarHideWords": ["translate"],
            "subagentSidebarMinWords": 3,
        }});
        let rules = Rules::from_user(Some(&doc), false);
        assert_eq!(
            decide("run the benchmark", Requested::Auto, &rules).place,
            Place::User
        );
        assert_eq!(
            decide("translate these five strings now", Requested::Auto, &rules).place,
            Place::None
        );
        assert_eq!(
            decide("fix the crash please", Requested::Auto, &rules).place,
            Place::User
        );
        assert!(
            rules.show_words.contains(&"design".to_owned()),
            "built-ins stay"
        );
        assert_eq!(
            Requested::parse("Visible"),
            Some(Requested::Place(Place::User))
        );
        assert_eq!(Requested::parse("maybe"), None);
    }
}
