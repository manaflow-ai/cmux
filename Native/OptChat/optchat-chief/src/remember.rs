//! `remember(text)`: the Chief keeps a lasting preference of the person in
//! their profile (`optchat/person.md`, a676 2026-10-26, Lawrence: "Chief
//! needs to feel like Instinct/Muse ... remembers the person's preferences").
//!
//! Before, a preference lived only in the chat: once the view summarized it
//! away, the Chief had to zoom to find it, and a new Chief home never had it.
//! The profile heads every turn's system prompt, so a line kept there holds in
//! every later host start without a lookup. The chat keeps the call, so the
//! running host follows it at once too.
//!
//! One line per preference, under `## Learned`, dated: `- TEXT (learned
//! YYYY-MM-DD)`. A line the profile already holds (same words, any case and
//! spacing) is a `noop`. A text that is empty, longer than [`REMEMBER_MAX`]
//! characters, holds a line break or a control character, or looks like a
//! credential is refused, never edited. The file is written whole (a temp
//! file, then a rename), so a crash leaves the old profile or the new one.

use std::path::Path;

/// The longest preference, in characters.
pub use chief_kernel::tools::REMEMBER_MAX;
/// The profile section learned preferences go under.
pub const LEARNED_HEADING: &str = "## Learned";

/// Words of `s`, lowercased, without punctuation at their ends: how two
/// preferences compare.
fn words(s: &str) -> String {
    s.split_whitespace()
        .map(|w| {
            w.trim_matches(|c: char| !c.is_alphanumeric())
                .to_lowercase()
        })
        .filter(|w| !w.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
}

/// The text `remember` keeps, or why it refuses it.
pub fn clean(text: &str) -> Result<String, String> {
    let text = text.trim().trim_start_matches(['-', '*', ' ']).trim();
    if text.is_empty() {
        return Err("remember: `text` must be a non-empty preference".into());
    }
    if text.chars().count() > REMEMBER_MAX {
        return Err(format!(
            "remember: keep it to one short line ({REMEMBER_MAX} characters at most)"
        ));
    }
    if text.chars().any(char::is_control) {
        return Err("remember: one line only, with no control characters".into());
    }
    if crate::agent_memory::notes::looks_secret(text) {
        return Err(
            "remember: refused, the text looks like a credential; never keep one in the profile"
                .into(),
        );
    }
    Ok(text.to_owned())
}

/// Adds `text` to the profile at `person` as a learned line dated `date`
/// (`YYYY-MM-DD`). Answers `outcome: done|noop. ...`.
pub fn remember(person: &Path, text: &str, date: &str) -> Result<String, String> {
    let text = clean(text)?;
    let old = match std::fs::read_to_string(person) {
        Ok(t) => t,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            crate::prompt::DEFAULT_PERSON.to_owned()
        }
        Err(e) => return Err(format!("remember: cannot read {}: {e}", person.display())),
    };
    let want = words(&text);
    let known = old.lines().any(|line| {
        let line = line.trim().trim_start_matches(['-', '*']).trim();
        // A learned line's date is not part of the preference.
        let line = match line.rfind(" (learned ") {
            Some(at) if line.ends_with(')') => &line[..at],
            _ => line,
        };
        !want.is_empty() && words(line) == want
    });
    if known {
        return Ok("outcome: noop. the profile already holds this preference".into());
    }
    let entry = format!("- {text} (learned {date})");
    let mut new = old.trim_end().to_owned();
    match new.find(LEARNED_HEADING) {
        // Under the heading, after its last line: the section runs to the
        // next heading or the end.
        Some(at) => {
            let body = at + LEARNED_HEADING.len();
            let end = new[body..].find("\n#").map_or(new.len(), |n| body + n);
            let head = new[..end].trim_end().to_owned();
            let tail = new[end..].to_owned();
            new = format!("{head}\n{entry}{tail}");
        }
        None => {
            new = format!("{new}\n\n{LEARNED_HEADING}\n\n{entry}");
        }
    }
    new.push('\n');
    if let Some(dir) = person.parent() {
        std::fs::create_dir_all(dir)
            .map_err(|e| format!("remember: cannot make {}: {e}", dir.display()))?;
    }
    let tmp = person.with_extension(format!("md.remember.{}", std::process::id()));
    std::fs::write(&tmp, &new)
        .and_then(|()| std::fs::rename(&tmp, person))
        .map_err(|e| {
            let _ = std::fs::remove_file(&tmp);
            format!("remember: cannot write {}: {e}", person.display())
        })?;
    Ok(format!(
        "outcome: done. kept in {}: \"{text}\". It holds from now on (this chat) and in every later turn's profile",
        person.display()
    ))
}

/// Today in local time, `YYYY-MM-DD`.
pub fn today() -> String {
    chrono::Local::now().format("%Y-%m-%d").to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_preference_goes_under_learned_once() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("optchat/person.md");
        let a = remember(&p, "Reply in one short bullet list.", "2026-10-26").unwrap();
        assert!(a.starts_with("outcome: done"), "{a}");
        let text = std::fs::read_to_string(&p).unwrap();
        assert!(
            text.starts_with("# The user"),
            "default profile kept: {text}"
        );
        assert!(
            text.contains("## Learned\n\n- Reply in one short bullet list. (learned 2026-10-26)\n"),
            "{text}"
        );
        let again = remember(&p, "  reply in one SHORT bullet list ", "2026-10-27").unwrap();
        assert!(again.starts_with("outcome: noop"), "{again}");
        remember(&p, "Default project is cmux-next.", "2026-10-27").unwrap();
        let text = std::fs::read_to_string(&p).unwrap();
        assert_eq!(text.matches("## Learned").count(), 1, "{text}");
        assert!(
            text.ends_with("- Default project is cmux-next. (learned 2026-10-27)\n"),
            "{text}"
        );
    }

    #[test]
    fn a_line_the_user_wrote_counts_as_known() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("person.md");
        std::fs::write(&p, "# The user\n\n- Never force push.\n\n## Other\n\n- x\n").unwrap();
        assert!(
            remember(&p, "never force push", "d")
                .unwrap()
                .starts_with("outcome: noop")
        );
    }

    #[test]
    fn secrets_newlines_and_empty_texts_are_refused() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("person.md");
        assert!(remember(&p, "", "d").is_err());
        assert!(remember(&p, "a\nb", "d").is_err());
        assert!(remember(&p, "my key is ghp_abcdefghijklmnopqrstuvwxyz0123", "d").is_err());
        assert!(remember(&p, &"x".repeat(REMEMBER_MAX + 1), "d").is_err());
        assert!(!p.exists(), "nothing written");
    }
}
