//! A Chief's record as its system text shows it (the "This Chief" block).

use serde_json::Value;

/// The parts of a Chief's record its prompt shows.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Record {
    pub display_name: String,
    pub role: String,
    pub personality: String,
    pub instructions: String,
    pub is_default: bool,
}

impl Record {
    /// A record from its wire JSON; a missing field is empty (false).
    pub fn from_json(v: &Value) -> Record {
        let text = |k: &str| {
            v.get(k)
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned()
        };
        Record {
            display_name: text("display_name"),
            role: text("role"),
            personality: text("personality"),
            instructions: text("instructions"),
            is_default: v
                .get("is_default")
                .and_then(Value::as_bool)
                .unwrap_or(false),
        }
    }
}

/// The record's block of the system text, always after the base rules. None
/// for the default Chief with no profile text, so its prompt stays what it
/// was before Chiefs had records.
pub fn render_record(r: &Record) -> Option<String> {
    let (role, personality, added) = (r.role.trim(), r.personality.trim(), r.instructions.trim());
    let plain_default = r.is_default
        && role.is_empty()
        && personality.is_empty()
        && added.is_empty()
        && matches!(r.display_name.trim(), "" | "Chief");
    if plain_default {
        return None;
    }
    let mut me = vec![format!("Name: {}", r.display_name.trim())];
    if !role.is_empty() {
        me.push(format!("Role: {role}"));
    }
    if !personality.is_empty() {
        me.push(format!("Personality: {personality}"));
    }
    let mut text = format!(
        "## This Chief (the rules above come first)\n{}",
        me.join("\n")
    );
    if !added.is_empty() {
        text.push_str(&format!(
            "\n\n## Added instructions (the rules above come first)\n{added}"
        ));
    }
    Some(text)
}
