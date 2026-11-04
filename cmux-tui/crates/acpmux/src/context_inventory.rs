//! Structured effective prompt context for the Context viewer.
//!
//! Harnesses expose different levels of detail. This module deliberately keeps the
//! inventory honest: token counts reported by a harness are retained, while text is
//! returned only for cmux-owned additions (or a verified local preset file).

use crate::config::{Config, ContextOverrides};
use crate::store::SessionMeta;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::path::Path;

/// A token count plus its origin. `text` is absent when the harness did not expose
/// the underlying bytes (for example Claude's built-in system prompt).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ContextPart {
    pub id: String,
    pub source: String,
    pub label: String,
    pub tokens: u64,
    pub included: bool,
    pub editable: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub struct ContextInventory {
    pub parts: Vec<ContextPart>,
    pub total_tokens: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_tokens: Option<u64>,
    pub overrides: ContextOverrideView,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub struct ContextOverrideView {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub user: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project: Option<String>,
    pub project_key: String,
}

/// Approximate tokens for text we own. A harness-reported count is always preferred.
pub fn estimated_tokens(text: &str) -> u64 {
    text.chars().count().div_ceil(4) as u64
}

fn push_breakdown(parts: &mut Vec<ContextPart>, breakdown: &Value) {
    for (index, category) in breakdown
        .get("categories")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .enumerate()
    {
        let id = category
            .get("id")
            .and_then(Value::as_str)
            .or_else(|| category.get("name").and_then(Value::as_str))
            .unwrap_or("category");
        let label = category
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or(id);
        let kind = category.get("kind").and_then(Value::as_str).unwrap_or("used");
        let tokens = category.get("tokens").and_then(Value::as_u64).unwrap_or(0);
        parts.push(ContextPart {
            id: format!("harness-category-{index}-{id}"),
            source: "harness".into(),
            label: label.into(),
            tokens,
            included: kind != "free",
            editable: false,
            text: None,
        });
    }
    for (index, file) in breakdown
        .get("memoryFiles")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .enumerate()
    {
        let path = file.get("path").and_then(Value::as_str).unwrap_or("memory file");
        parts.push(ContextPart {
            id: format!("memory-{index}"),
            source: "memory".into(),
            label: path.into(),
            tokens: file.get("tokens").and_then(Value::as_u64).unwrap_or(0),
            included: true,
            editable: false,
            text: None,
        });
    }
    for (index, tool) in breakdown
        .get("mcpTools")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .enumerate()
    {
        let name = tool.get("name").and_then(Value::as_str).unwrap_or("MCP tool");
        parts.push(ContextPart {
            id: format!("mcp-tool-{index}"),
            source: "mcp".into(),
            label: name.into(),
            tokens: tool.get("tokens").and_then(Value::as_u64).unwrap_or(0),
            included: tool.get("isLoaded").and_then(Value::as_bool).unwrap_or(true),
            editable: false,
            text: None,
        });
    }
    if let Some(skills) = breakdown.get("skills") {
        for (index, skill) in skills
            .get("skillFrontmatter")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .enumerate()
        {
            let name = skill.get("name").and_then(Value::as_str).unwrap_or("skill");
            parts.push(ContextPart {
                id: format!("skill-{index}"),
                source: "skill".into(),
                label: name.into(),
                tokens: skill.get("tokens").and_then(Value::as_u64).unwrap_or(0),
                included: true,
                editable: false,
                text: None,
            });
        }
    }
}

fn verified_prompt_text(meta: &SessionMeta, cfg: &Config) -> Option<String> {
    let name = meta.preset.as_deref()?;
    let preset = cfg.presets.get(name)?;
    let sha = preset.system_prompt_sha256.as_deref()?;
    let dir = cfg.presets_dir()?;
    let path = crate::config::checked_system_prompt(&dir, name, sha).ok()?;
    std::fs::read_to_string(path).ok()
}

/// Build an inventory from the latest harness report and cmux-owned state.
pub fn inventory(meta: &SessionMeta, cfg: &Config) -> ContextInventory {
    let mut parts = Vec::new();
    let breakdown = meta.context_breakdown.as_ref();
    if let Some(breakdown) = breakdown {
        push_breakdown(&mut parts, breakdown);
    }
    if let Some(text) = verified_prompt_text(meta, cfg) {
        parts.push(ContextPart {
            id: "cmux-system-prompt".into(),
            source: "cmux-preset".into(),
            label: "Preset system prompt".into(),
            tokens: estimated_tokens(&text),
            included: true,
            editable: true,
            text: Some(text),
        });
    }
    let project_key = meta.cwd.to_string_lossy().into_owned();
    let (user, project) = match cfg.context_overrides.for_project(&meta.cwd) {
        Some(("project", text)) => (cfg.context_overrides.user.clone(), Some(text.to_owned())),
        Some(("user", text)) => (Some(text.to_owned()), None),
        _ => (cfg.context_overrides.user.clone(), None),
    };
    if let Some(text) = user.as_deref() {
        parts.push(ContextPart {
            id: "cmux-user-override".into(), source: "cmux-user".into(),
            label: "User override".into(), tokens: estimated_tokens(text), included: true,
            editable: true, text: Some(text.into()),
        });
    }
    if let Some(text) = project.as_deref() {
        parts.push(ContextPart {
            id: "cmux-project-override".into(), source: "cmux-project".into(),
            label: "Project override".into(), tokens: estimated_tokens(text), included: true,
            editable: true, text: Some(text.into()),
        });
    }
    let total_tokens = breakdown
        .and_then(|v| v.get("totalTokens").and_then(Value::as_u64))
        .unwrap_or_else(|| parts.iter().filter(|p| p.included).map(|p| p.tokens).sum());
    let max_tokens = breakdown.and_then(|v| v.get("maxTokens").and_then(Value::as_u64));
    ContextInventory {
        parts,
        total_tokens,
        max_tokens,
        overrides: ContextOverrideView { user, project, project_key },
    }
}

/// A prompt block that is hidden from the transcript but delivered to the harness.
pub fn override_block(text: &str, scope: &str) -> Value {
    json!({"type":"text", "text": format!("<cmux-{scope}-context>{text}</cmux-{scope}-context>"),
        "_meta":{"acpmux":{"context":true,"contextSource":format!("cmux-{scope}")}}})
}

pub fn validate_override(text: &str) -> Result<(), String> {
    if text.trim().is_empty() || text.len() > crate::prompt_context::MAX_BYTES {
        Err(format!("override must be 1 to {} bytes of text", crate::prompt_context::MAX_BYTES))
    } else { Ok(()) }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::{Path, PathBuf};

    #[test]
    fn inventory_preserves_harness_counts_and_marks_cmux_text_editable() {
        let mut meta: SessionMeta = serde_json::from_value(json!({"schema":"acpmux.session.v1","id":"s","name":"s","harness":"claude","cwd":"/repo","status":"ready","createdAt":0,"updatedAt":0})).unwrap();
        meta.context_breakdown = Some(json!({"categories":[{"id":"system_prompt","name":"System prompt","tokens":20,"kind":"used"}],"totalTokens":20,"maxTokens":100}));
        let mut cfg = Config::default();
        cfg.context_overrides.user = Some("read concurrently".into());
        let got = inventory(&meta, &cfg);
        assert_eq!(got.total_tokens, 20);
        assert!(got.parts.iter().any(|p| p.source == "harness" && p.tokens == 20 && !p.editable));
        assert!(got.parts.iter().any(|p| p.source == "cmux-user" && p.editable));
    }

    #[test]
    fn override_block_is_hidden_context_and_has_approximate_tokens() {
        let block = override_block("read concurrently", "project");
        assert!(crate::prompt_context::is_context(&block));
        assert!(crate::prompt_context::is_context_text(block["text"].as_str().unwrap()));
        assert_eq!(estimated_tokens("12345678"), 2);
    }

    #[test]
    fn overrides_choose_project_over_user_and_clear() {
        let mut overrides = ContextOverrides { user: Some("u".into()), projects: Default::default() };
        let cwd = Path::new("/repo");
        overrides.set("project", Some(cwd), Some("p".into())).unwrap();
        assert_eq!(overrides.for_project(cwd), Some(("project", "p")));
        overrides.set("project", Some(cwd), None).unwrap();
        assert_eq!(overrides.for_project(cwd), Some(("user", "u")));
    }
}
