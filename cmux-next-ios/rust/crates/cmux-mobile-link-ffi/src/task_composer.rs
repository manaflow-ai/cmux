//! New Task's composer rules on the phone (CmuxMobileModel's `TaskComposer.swift`): the command
//! a terminal launch types into the Mac's shell, the image types an agent takes, and what a tap on
//! an agent's row does to the chosen agents.
//!
//! Lawrence (2026-11-02): "move as much from swift into rust as possible". Leo (2026-11-25): "i
//! was wondering why we even have swift at all". Swift hands these functions plain values and
//! applies what they return; the rules and their tests live here.

/// Where a terminal launch starts, and what it runs: the agent's CLI with the task.
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct TaskTerminalLaunch {
    /// The task as typed (already trimmed by the composer).
    pub prompt: String,
    /// The model id; `None`, empty or `default` leaves the CLI's own default.
    pub model: Option<String>,
    /// The agent's family (`claude`, `codex`): which CLI runs.
    pub family: Option<String>,
    /// The effort level, or `None` for the model's default.
    pub effort: Option<String>,
    /// The mode the agent starts in (Claude Code's permission mode), or `None`.
    pub mode: Option<String>,
    /// The workspace's folder to `cd` to first, or `None` to run where the shell is.
    pub folder: Option<String>,
    /// Paths of the task's uploaded photos and files, named after the prompt.
    pub attachment_paths: Vec<String>,
}

/// The line a terminal launch types into the new workspace's shell (zsh or bash, the Mac's
/// default shells): `cd` to the folder and, only if that worked, the agent's CLI with its model
/// and the prompt, the uploaded attachments' paths after it. `None` for an agent with no known
/// CLI. Every value is one ANSI-C quoted word (`$'…'`), so nothing in it runs. Options are
/// `--flag=value` and the prompt comes after `--`, so a value starting with `-` is never taken
/// for an option.
#[uniffi::export]
pub fn task_terminal_line(launch: TaskTerminalLaunch) -> Option<String> {
    let mut text = launch.prompt;
    if !launch.attachment_paths.is_empty() {
        text.push_str("\n\nAttached files (read them):\n");
        text.push_str(&launch.attachment_paths.join("\n"));
    }
    let prompt = ansi_quoted(&text);
    let model_flag = launch
        .model
        .filter(|model| !model.is_empty() && model != "default")
        .map(|model| format!(" --model={}", ansi_quoted(&model)))
        .unwrap_or_default();
    let command = match launch.family.as_deref() {
        Some("claude") => {
            // The mode and effort as Claude Code's own flags.
            let effort = flag(" --effort=", launch.effort.as_deref());
            let mode = flag(" --permission-mode=", launch.mode.as_deref());
            format!("claude{model_flag}{effort}{mode} -- {prompt}")
        }
        Some("codex") => {
            // The effort as Codex's config override (`-c key=value`).
            let effort = launch
                .effort
                .map(|effort| format!(" -c {}", ansi_quoted(&format!("model_reasoning_effort={effort}"))))
                .unwrap_or_default();
            format!("codex{model_flag}{effort} -- {prompt}")
        }
        _ => return None,
    };
    Some(match launch.folder {
        Some(folder) => format!("cd -- {} && {command}\n", folder_word(&folder)),
        None => format!("{command}\n"),
    })
}

fn flag(name: &str, value: Option<&str>) -> String {
    value.map(|value| format!("{name}{}", ansi_quoted(value))).unwrap_or_default()
}

/// A folder as one shell word: `~/x` keeps its `~` (expanded by the shell), the rest is quoted.
fn folder_word(folder: &str) -> String {
    if folder == "~" {
        return "~".to_owned();
    }
    match folder.strip_prefix("~/") {
        Some(rest) => format!("~/{}", ansi_quoted(rest)),
        None => ansi_quoted(folder),
    }
}

/// U+202A–202E and U+2066–2069: they reorder what a terminal shows, not what runs.
fn is_bidi_control(c: char) -> bool {
    matches!(c, '\u{202A}'..='\u{202E}' | '\u{2066}'..='\u{2069}')
}

/// `$'…'` with `\\`, `\'`, `\n` and `\t` escaped; control characters (C0, DEL, C1) and the
/// bidirectional overrides dropped. Other format characters stay (the joiners Persian, Indic
/// scripts and emoji need), as nothing in a quoted word acts on them.
fn ansi_quoted(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + 3);
    out.push_str("$'");
    for c in text.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '\'' => out.push_str("\\'"),
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
            c if c.is_control() || is_bidi_control(c) => {}
            c => out.push(c),
        }
    }
    out.push('\'');
    out
}

/// The MIME type of an attached image from its bytes' signature (the first 12 are enough):
/// PNG, JPEG, GIF or WebP, the formats agents take; `None` for any other.
#[uniffi::export]
pub fn task_image_mime_type(head: Vec<u8>) -> Option<String> {
    if head.len() < 12 {
        return None;
    }
    let mime = if head.starts_with(&[0x89, 0x50, 0x4E, 0x47]) {
        "image/png"
    } else if head.starts_with(&[0xFF, 0xD8, 0xFF]) {
        "image/jpeg"
    } else if head.starts_with(b"GIF8") {
        "image/gif"
    } else if head.starts_with(b"RIFF") && &head[8..12] == b"WEBP" {
        "image/webp"
    } else {
        return None;
    };
    Some(mime.to_owned())
}

/// What a tap on an agent's row did.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum TaskPickChange {
    Added,
    Removed,
    /// The last agent stays: a task always has one.
    KeptLast,
    /// `limit` agents are chosen already.
    AtLimit,
    /// A phone can't start this agent.
    Unavailable,
}

/// A tap's outcome: what it did, and the chosen agents after it (harness ids, in the order they
/// were chosen). Swift keeps each kept agent's settings and makes a fresh pick for a new id.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TaskPickToggle {
    pub change: TaskPickChange,
    pub picks: Vec<String>,
}

/// A tap on `harness`'s row: picks it, or unpicks it unless it is the last. With no pick, the
/// agent the task would start (`fallback`, shown checked) becomes a real pick first. At most
/// `limit` agents are chosen.
#[uniffi::export]
pub fn task_pick_toggle(
    picks: Vec<String>,
    harness: String,
    can_start: bool,
    fallback: Option<String>,
    limit: u32,
) -> TaskPickToggle {
    if !can_start {
        return TaskPickToggle { change: TaskPickChange::Unavailable, picks };
    }
    let mut picks = picks;
    if picks.is_empty()
        && let Some(fallback) = fallback
    {
        picks.push(fallback);
    }
    let change = if let Some(index) = picks.iter().position(|id| *id == harness) {
        if picks.len() > 1 {
            picks.remove(index);
            TaskPickChange::Removed
        } else {
            TaskPickChange::KeptLast
        }
    } else if picks.len() >= limit as usize {
        TaskPickChange::AtLimit
    } else {
        picks.push(harness);
        TaskPickChange::Added
    };
    TaskPickToggle { change, picks }
}

#[cfg(test)]
#[path = "task_composer_tests.rs"]
mod tests;
