//! What an agent is called, as the GUI chat names it (`webviews/.../agents.ts` `agentDisplayName`,
//! 7b72b14d1187: "DeepSeek", not "Deepseek"). acpmux names a harness by its config id ("codex",
//! "claude-sr", "providers/deepseek"), which is not what the agent is called.

const KNOWN: &[(&str, &str)] = &[
    ("claude", "Claude Code"),
    ("codex", "Codex"),
    ("gemini", "Gemini CLI"),
    ("muse", "Muse Code"),
    ("opencode", "OpenCode"),
    ("cursor", "Cursor"),
    ("pi", "Pi"),
    ("goose", "Goose"),
    ("amp", "Amp"),
    ("qwen", "Qwen Code"),
    ("copilot", "GitHub Copilot"),
    ("aider", "Aider"),
    ("deepseek", "DeepSeek"),
    ("chief", "Chief"),
];

fn words(id: &str) -> impl Iterator<Item = &str> {
    // A peer's harness ("providers/deepseek") is named by its last part.
    let id = id.rsplit('/').next().unwrap_or(id);
    id.split(|c: char| c == '-' || c == '_' || c.is_whitespace()).filter(|w| !w.is_empty())
}

/// The name this app knows a harness id as ("claude-sr" is Claude Code), or None.
pub(crate) fn known(id: &str) -> Option<&'static str> {
    let key = words(id).next()?.to_ascii_lowercase();
    KNOWN.iter().find(|(k, _)| *k == key).map(|(_, name)| *name)
}

/// The agent's name for a harness id; an unknown id is title-cased ("my-agent" is "My Agent").
pub(crate) fn display_name(id: &str) -> String {
    if let Some(name) = known(id) {
        return name.to_owned();
    }
    let titled: Vec<String> = words(id)
        .map(|w| {
            let mut c = w.chars();
            c.next().map(|f| f.to_uppercase().chain(c).collect()).unwrap_or_default()
        })
        .collect();
    if titled.is_empty() { id.to_owned() } else { titled.join(" ") }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_agents_as_the_gui_does() {
        assert_eq!(display_name("deepseek"), "DeepSeek");
        assert_eq!(display_name("providers/deepseek"), "DeepSeek");
        assert_eq!(display_name("claude-sr"), "Claude Code");
        assert_eq!(display_name("opencode-v2"), "OpenCode");
        assert_eq!(display_name("my-agent"), "My Agent");
        assert_eq!(known("cmux"), None);
    }
}
