//! Whether a Chief subagent gets a sidebar workspace when it starts (a1018,
//! Lawrence 2026-11-05: "the chief will make the decision if the workspace is
//! visible in the sidebar or not", with heuristics the user shapes; aziz: "not
//! liking how new agents by chief don't appear in sidebar by default").
//!
//! The Chief chooses per spawn (`spawn(sidebar)`, or a `Sidebar:` line in
//! one task): `shown`, `hidden` or `auto`. `auto`, the default, applies
//! [`Rules`]: a task that mentions a show word (UI, design, screenshots,
//! anything that needs the user) shows; one that mentions a hide word (a
//! lookup, a cleanup, a land-queue follower) hides; otherwise a task of at
//! least `min_words` words (a bigger piece of work the user will want to watch
//! or join) shows and a shorter one hides.
//!
//! The user shapes the rules in cmux-next.json (Settings > Chief >
//! Subagents), read at each spawn: `chief.subagentSidebar` (`auto`,
//! `always`, `never`) overrides every choice, `chief.subagentSidebarShowWords`
//! and `chief.subagentSidebarHideWords` add words to the built-in lists, and
//! `chief.subagentSidebarMinWords` sets the length rule. The older Chief
//! setting `subagents.showWorkspaces` true still shows every subagent.

use serde_json::Value;

/// The cmux-next.json key of [`Mode`].
pub const MODE_KEY: &str = "chief.subagentSidebar";
/// The cmux-next.json key of the user's extra show words.
pub const SHOW_WORDS_KEY: &str = "chief.subagentSidebarShowWords";
/// The cmux-next.json key of the user's extra hide words.
pub const HIDE_WORDS_KEY: &str = "chief.subagentSidebarHideWords";
/// The cmux-next.json key of [`Rules::min_words`].
pub const MIN_WORDS_KEY: &str = "chief.subagentSidebarMinWords";

/// The words of a task (outside its header lines) from which `auto` shows it.
pub const DEFAULT_MIN_WORDS: usize = 50;

/// Words that show a task under `auto`: work the user looks at or must act on.
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

/// Words that hide a task under `auto`: short errands nobody watches.
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
];

/// What the Chief asked for one task.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Requested {
    /// Always a sidebar workspace.
    Shown,
    /// No sidebar workspace; `control show` adds it later.
    Hidden,
    /// The rules decide.
    Auto,
}

impl Requested {
    /// `shown`/`show`/`visible`, `hidden`/`hide`, or `auto` (any case).
    pub fn parse(value: &str) -> Option<Requested> {
        match value.trim().to_ascii_lowercase().as_str() {
            "shown" | "show" | "visible" => Some(Requested::Shown),
            "hidden" | "hide" => Some(Requested::Hidden),
            "auto" => Some(Requested::Auto),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Requested::Shown => "shown",
            Requested::Hidden => "hidden",
            Requested::Auto => "auto",
        }
    }

    /// The task's own `Sidebar:` line, else `auto`.
    pub fn of_task(task: &str) -> Requested {
        crate::workspaces::header(task, "sidebar")
            .and_then(|v| Requested::parse(&v))
            .unwrap_or(Requested::Auto)
    }
}

/// The user's override (`chief.subagentSidebar`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Mode {
    /// The Chief chooses; its `auto` applies the rules.
    #[default]
    Auto,
    /// Every subagent shows.
    Always,
    /// No subagent shows (one that asks before it acts still does).
    Never,
}

/// How `auto` decides, as the user shaped it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Rules {
    pub mode: Mode,
    /// `subagents.showWorkspaces` (the Chief setting before a1018) is on.
    pub legacy_show_all: bool,
    /// Lowercase words or phrases that show a task.
    pub show_words: Vec<String>,
    /// Lowercase words or phrases that hide a task.
    pub hide_words: Vec<String>,
    /// Task length (words) from which a task shows.
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
        let mode = match get(MODE_KEY)
            .as_ref()
            .and_then(Value::as_str)
            .map(str::trim)
        {
            Some("always") => Mode::Always,
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
}

/// The decision for one task, with the reason the spawn answer gives.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Choice {
    pub show: bool,
    pub why: String,
}

/// Whether `task` (with `requested`, the Chief's choice) gets a sidebar
/// workspace under `rules`.
pub fn decide(task: &str, requested: Requested, rules: &Rules) -> Choice {
    let choice = |show: bool, why: String| Choice { show, why };
    match rules.mode {
        Mode::Always => return choice(true, format!("the setting {MODE_KEY} is always")),
        Mode::Never => return choice(false, format!("the setting {MODE_KEY} is never")),
        Mode::Auto => {}
    }
    if rules.legacy_show_all {
        return choice(
            true,
            format!(
                "the setting {} is on",
                crate::chief_settings::SHOW_SUBAGENT_WORKSPACES
            ),
        );
    }
    match requested {
        Requested::Shown => return choice(true, "you asked for sidebar: shown".into()),
        Requested::Hidden => return choice(false, "you asked for sidebar: hidden".into()),
        Requested::Auto => {}
    }
    let body = body(task);
    let text = body.to_lowercase();
    if let Some(w) = rules.show_words.iter().find(|w| mentions(&text, w)) {
        return choice(true, format!("auto: the task mentions \"{w}\""));
    }
    if let Some(w) = rules.hide_words.iter().find(|w| mentions(&text, w)) {
        return choice(false, format!("auto: the task mentions \"{w}\""));
    }
    let n = body.split_whitespace().count();
    if n >= rules.min_words {
        choice(
            true,
            format!("auto: a bigger task ({n} words, from {})", rules.min_words),
        )
    } else {
        choice(
            false,
            format!("auto: a short task ({n} words, under {})", rules.min_words),
        )
    }
}

/// `task` without its `Title:`, `Group:` and `Sidebar:` lines.
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
    fn a_bigger_task_shows_and_a_short_errand_hides_by_default() {
        let big = format!(
            "Title: Sidebar rework\nFix the sidebar. {}",
            "word ".repeat(60)
        );
        assert!(auto(&big).show, "{:?}", auto(&big));
        let short = "Title: PR check\nsay hello";
        let c = auto(short);
        assert!(!c.show, "{c:?}");
        assert!(c.why.contains("short task"), "{c:?}");
    }

    #[test]
    fn ui_and_input_words_show_and_errand_words_hide_whole_words_only() {
        assert!(auto("Fix the blue ring in the UI").show);
        assert!(auto("Make 5 design variants").show);
        assert!(auto("This one needs you to pick").show);
        assert!(!auto("Clean up the scratch branches").show);
        assert!(!auto("Follow landq entry 1234 until it lands").show);
        // "ui" is not "build", "poll" is not "polling-free".
        let c = auto("build it");
        assert!(c.why.contains("short task"), "{c:?}");
        // A show word wins over a hide word.
        assert!(auto("Clean up the UI padding").show);
    }

    #[test]
    fn the_chiefs_choice_wins_under_auto_and_the_users_mode_wins_over_it() {
        let task = "Sidebar: shown\nTitle: Lookup\nlook up a sha";
        assert!(auto(task).show);
        assert!(!auto("Sidebar: hidden\nRedesign the UI").show);
        let never = Rules::from_user(Some(&json!({"chief": {"subagentSidebar": "never"}})), true);
        assert!(!decide(task, Requested::Shown, &never).show);
        let always = Rules::from_user(Some(&json!({"chief.subagentSidebar": "always"})), false);
        assert!(decide("look up a sha", Requested::Hidden, &always).show);
        // The old Chief setting still shows everything under auto.
        let legacy = Rules::from_user(None, true);
        let c = decide("say hello", Requested::Hidden, &legacy);
        assert!(
            c.show && c.why.contains("subagents.showWorkspaces"),
            "{c:?}"
        );
    }

    #[test]
    fn the_user_adds_words_and_sets_the_length() {
        let doc = json!({"chief": {
            "subagentSidebarShowWords": ["Benchmark", " "],
            "subagentSidebarHideWords": ["translate"],
            "subagentSidebarMinWords": 3,
        }});
        let rules = Rules::from_user(Some(&doc), false);
        assert!(decide("run the benchmark", Requested::Auto, &rules).show);
        assert!(!decide("translate these five strings now", Requested::Auto, &rules).show);
        assert!(decide("fix the crash please", Requested::Auto, &rules).show);
        assert!(
            rules.show_words.contains(&"design".to_owned()),
            "built-ins stay"
        );
        assert_eq!(Requested::parse("Visible"), Some(Requested::Shown));
        assert_eq!(Requested::parse("maybe"), None);
    }
}
