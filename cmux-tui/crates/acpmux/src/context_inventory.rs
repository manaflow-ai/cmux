//! Structured effective prompt context for the Context viewer.
//!
//! Harnesses expose different levels of detail. This module deliberately keeps the
//! inventory honest: token counts reported by a harness are retained, while text is
//! returned only for cmux-owned additions (or a verified local preset file).

use crate::config::Config;
use crate::store::SessionMeta;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::BTreeMap;
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
    /// `measured` comes from the harness, `estimated` is derived by cmux, and
    /// `unavailable` means the provider did not expose this part.
    pub measurement: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_bytes: Option<u64>,
    /// Delivery channel, when known. Describing a source never injects it again.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub channel: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub struct ContextInventory {
    pub parts: Vec<ContextPart>,
    /// Provider total when reported; otherwise the cmux-only estimate. Detail rows overlap.
    pub total_tokens: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_total_tokens: Option<u64>,
    pub cmux_tokens: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_tokens: Option<u64>,
    pub can_edit_overrides: bool,
    pub overrides: ContextOverrideView,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub struct ContextOverrideView {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default_text: Option<String>,
    pub user: Option<String>,
    pub project: Option<String>,
    pub project_key: String,
    pub cwd: String,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub parts: BTreeMap<String, ContextPromptOverrideView>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ContextPromptOverrideView {
    pub label: String,
    pub default_text: String,
    pub user: Option<String>,
    pub project: Option<String>,
}

/// Approximate tokens for text we own. A harness-reported count is always preferred.
pub fn estimated_tokens(text: &str) -> u64 {
    text.chars().count().saturating_add(3).checked_div(4).unwrap_or(0) as u64
}

fn push_breakdown(parts: &mut Vec<ContextPart>, breakdown: &Value) {
    for (index, category) in
        breakdown.get("categories").and_then(Value::as_array).into_iter().flatten().enumerate()
    {
        let id = category
            .get("id")
            .and_then(Value::as_str)
            .or_else(|| category.get("name").and_then(Value::as_str))
            .unwrap_or("category");
        let label = category.get("name").and_then(Value::as_str).unwrap_or(id);
        let kind = category.get("kind").and_then(Value::as_str).unwrap_or("used");
        let tokens = category.get("tokens").and_then(Value::as_u64).unwrap_or(0);
        parts.push(ContextPart {
            id: format!("harness-category-{index}-{id}"),
            source: "harness".into(),
            label: label.into(),
            tokens,
            included: kind != "free",
            editable: false,
            measurement: "measured".into(),
            source_bytes: None,
            channel: None,
            text: None,
        });
    }
    for (index, file) in
        breakdown.get("memoryFiles").and_then(Value::as_array).into_iter().flatten().enumerate()
    {
        let path = file.get("path").and_then(Value::as_str).unwrap_or("memory file");
        parts.push(ContextPart {
            id: format!("memory-{index}"),
            source: "memory".into(),
            label: path.into(),
            tokens: file.get("tokens").and_then(Value::as_u64).unwrap_or(0),
            included: true,
            editable: false,
            measurement: "measured".into(),
            source_bytes: None,
            channel: None,
            text: None,
        });
    }
    for (index, tool) in
        breakdown.get("mcpTools").and_then(Value::as_array).into_iter().flatten().enumerate()
    {
        let name = tool.get("name").and_then(Value::as_str).unwrap_or("MCP tool");
        parts.push(ContextPart {
            id: format!("mcp-tool-{index}"),
            source: "mcp".into(),
            label: name.into(),
            tokens: tool.get("tokens").and_then(Value::as_u64).unwrap_or(0),
            included: tool.get("isLoaded").and_then(Value::as_bool).unwrap_or(true),
            editable: false,
            measurement: "measured".into(),
            source_bytes: None,
            channel: None,
            text: None,
        });
    }
    if let Some(skills) = breakdown.get("skills") {
        for (index, skill) in skills.as_array().into_iter().flatten().enumerate() {
            let name = skill.get("name").and_then(Value::as_str).unwrap_or("skill");
            parts.push(ContextPart {
                id: format!("skill-{index}"),
                source: "skill".into(),
                label: name.into(),
                tokens: skill.get("tokens").and_then(Value::as_u64).unwrap_or(0),
                included: true,
                editable: false,
                measurement: "measured".into(),
                source_bytes: None,
                channel: None,
                text: None,
            });
        }
    }
}

fn verified_prompt_text(meta: &SessionMeta, cfg: &Config) -> Option<String> {
    if meta.remote_origin
        || cfg.harnesses.get(&meta.harness)?.kind != crate::config::HarnessKind::ClaudeStdio
    {
        return None;
    }
    let name = meta.preset.as_deref()?;
    let preset = cfg.presets.get(name)?;
    let sha = preset.system_prompt_sha256.as_deref()?;
    let dir = cfg.presets_dir()?;
    let path = crate::config::checked_system_prompt(&dir, name, sha).ok()?;
    std::fs::read_to_string(path).ok()
}

/// Select an override only for a verified local preset. The session stores this
/// selection so editing settings cannot change a running chat's next respawn.
pub fn preset_override(meta: &SessionMeta, cfg: &Config) -> Option<String> {
    verified_prompt_text(meta, cfg)?;
    cfg.context_overrides
        .preset_prompts
        .get(meta.preset.as_deref()?)?
        .for_project(&meta.cwd)
        .map(str::to_owned)
}

pub fn preset_is_editable(meta: &SessionMeta, cfg: &Config) -> bool {
    verified_prompt_text(meta, cfg).is_some()
}

/// Build an inventory from the latest harness report and cmux-owned state.
pub fn inventory(meta: &SessionMeta, cfg: &Config) -> ContextInventory {
    let mut parts = Vec::new();
    let breakdown = meta.context_breakdown.as_ref();
    if let Some(breakdown) = breakdown {
        push_breakdown(&mut parts, breakdown);
    }
    let project_key = crate::config::ContextOverrides::project_key(&meta.cwd);
    let user = cfg.context_overrides.user.clone();
    let project = cfg.context_overrides.projects.get(&project_key).cloned();
    let mut override_parts = BTreeMap::new();
    if let Some(default_text) = verified_prompt_text(meta, cfg) {
        let values =
            meta.preset.as_deref().and_then(|name| cfg.context_overrides.preset_prompts.get(name));
        override_parts.insert(
            "cmux-system-prompt".into(),
            ContextPromptOverrideView {
                label: "Preset system prompt".into(),
                default_text,
                user: values.and_then(|v| v.user.clone()),
                project: values.and_then(|v| v.projects.get(&project_key).cloned()),
            },
        );
    }
    // These are the additions captured at creation, not settings edited since then.
    if let Some(snapshot) = &meta.cmux_context {
        parts.extend(snapshot.iter().cloned());
    }
    for part in parts.iter_mut().filter(|p| p.id == "cmux-system-prompt") {
        part.editable = override_parts.contains_key("cmux-system-prompt");
    }
    if breakdown.is_none() {
        parts.push(ContextPart {
            id: "harness-context-unavailable".into(),
            source: "harness".into(),
            label: "Harness context report unavailable".into(),
            tokens: 0,
            included: false,
            editable: false,
            measurement: "unavailable".into(),
            source_bytes: None,
            channel: None,
            text: None,
        });
    }
    let provider_total_tokens = breakdown
        .and_then(|v| v.get("totalTokens").and_then(Value::as_u64))
        .or_else(|| meta.usage.as_ref().and_then(|v| v.get("used")).and_then(Value::as_u64));
    // Category rows and their memory/tool/skill detail rows overlap. Never sum them.
    let cmux_tokens = parts
        .iter()
        .filter(|p| p.included && p.source.starts_with("cmux-"))
        .map(|p| p.tokens)
        .sum();
    let total_tokens = provider_total_tokens.unwrap_or(cmux_tokens);
    let max_tokens = breakdown
        .and_then(|v| v.get("maxTokens").and_then(Value::as_u64))
        .or_else(|| meta.usage.as_ref().and_then(|v| v.get("size")).and_then(Value::as_u64));
    ContextInventory {
        parts,
        total_tokens,
        provider_total_tokens,
        cmux_tokens,
        max_tokens,
        can_edit_overrides: true,
        overrides: ContextOverrideView {
            default_text: Some(crate::agent_tools::CONCURRENT_WORK_RULE.into()),
            user,
            project,
            project_key: project_key.clone(),
            cwd: meta.cwd.to_string_lossy().into_owned(),
            parts: override_parts,
        },
    }
}

/// A prompt block that is hidden from the transcript but delivered to the harness.
pub fn override_block(text: &str, scope: &str) -> Value {
    json!({"type":"text", "text": format!("<cmux-{scope}-context>{text}</cmux-{scope}-context>"),
        "_meta":{"acpmux":{"context":true,"contextSource":format!("cmux-{scope}")}}})
}

/// Capture preset bytes as well as the injected addition so later config edits do not
/// change the effective text reported for an existing chat.
pub fn snapshot_session(meta: &SessionMeta, cfg: &Config) -> Vec<ContextPart> {
    let mut parts = snapshot_for(cfg, &meta.cwd, &meta.harness);
    if let Some(default) = verified_prompt_text(meta, cfg) {
        let text = meta.cmux_preset_prompt.clone().unwrap_or(default);
        parts.push(ContextPart {
            id: "cmux-system-prompt".into(),
            source: "cmux-preset".into(),
            label: "Preset system prompt".into(),
            tokens: estimated_tokens(&text),
            included: true,
            editable: true,
            measurement: "estimated".into(),
            source_bytes: Some(text.len() as u64),
            channel: Some("system-prompt-file".into()),
            text: Some(text),
        });
    }
    parts
}

fn preset_part(text: String) -> ContextPart {
    ContextPart {
        id: "cmux-system-prompt".into(),
        source: "cmux-preset".into(),
        label: "Preset system prompt".into(),
        tokens: estimated_tokens(&text),
        included: true,
        editable: false,
        measurement: "estimated".into(),
        source_bytes: Some(text.len() as u64),
        channel: Some("system-prompt-file".into()),
        text: Some(text),
    }
}

/// Refresh only the preset part from the actual launch argv, after preset
/// resolution. Reading later settings would describe a future launch instead.
pub fn preset_source(argv: &[String]) -> Option<ContextPart> {
    let file = argv.windows(2).rev().find_map(|words| match words {
        [flag, file] if flag == "--system-prompt-file" => Some(file),
        _ => None,
    })?;
    std::fs::read_to_string(file).ok().map(preset_part)
}

pub fn record_preset_source(meta: &mut SessionMeta, part: Option<ContextPart>) {
    let snapshot = meta.cmux_context.get_or_insert_with(Vec::new);
    snapshot.retain(|part| part.source != "cmux-preset");
    if let Some(part) = part {
        snapshot.push(part);
    }
}

/// Append the captured default or override on the first written turn. All guidance
/// uses this one user-context channel, including sessions with no cmux MCP server.
/// Preset text is emitted separately by the harness's system-prompt argument.
pub fn append_snapshot(parts: Option<&[ContextPart]>, blocks: &mut Vec<Value>) {
    for part in parts.into_iter().flatten().filter(|p| {
        p.included
            && matches!(
                p.source.as_str(),
                "cmux-default" | "cmux-user" | "cmux-project" | GUIDANCE_SOURCE
            )
            && p.channel.as_deref().is_none_or(|channel| channel == "user-context")
    }) {
        if let Some(text) = part.text.as_deref() {
            let scope = part.source.strip_prefix("cmux-").unwrap_or("user");
            blocks.push(override_block(text, scope));
        }
    }
}

/// Refresh launch-derived rows while preserving creation-time guidance/preset bytes.
pub fn record_tool_sources(meta: &mut SessionMeta, parts: Vec<ContextPart>) {
    let snapshot = meta.cmux_context.get_or_insert_with(Vec::new);
    snapshot.retain(|part| !part.id.starts_with("cmux-source-"));
    snapshot.extend(parts);
}

/// The source of cmux's built-in chat guidance and the person's skill index
/// (`agent_guidance.rs`), sent as `<cmux-guidance-context>`.
pub const GUIDANCE_SOURCE: &str = "cmux-guidance";

/// [`snapshot`] plus the chat guidance for a session of profile `harness`. The guidance is
/// its own part, so a person's guidance override (which replaces the default rule) keeps it;
/// the `agents.guidance.*` settings turn it off.
pub fn snapshot_for(cfg: &Config, cwd: &Path, harness: &str) -> Vec<ContextPart> {
    let mut parts = snapshot(cfg, cwd);
    parts.extend(crate::agent_guidance::for_session(cfg, harness).map(guidance_part));
    parts
}

pub fn guidance_part(text: String) -> ContextPart {
    ContextPart {
        id: "cmux-guidance".into(),
        source: GUIDANCE_SOURCE.into(),
        label: "cmux chat guidance and your skills (first-turn context)".into(),
        tokens: estimated_tokens(&text),
        included: true,
        editable: false,
        measurement: "estimated".into(),
        source_bytes: Some(text.len() as u64),
        channel: Some("user-context".into()),
        text: Some(text),
    }
}

/// Capture settings once when the session is created. Project text replaces user text.
pub fn snapshot(cfg: &Config, cwd: &Path) -> Vec<ContextPart> {
    let (scope, text) = cfg
        .context_overrides
        .for_project(cwd)
        .unwrap_or(("default", crate::agent_tools::CONCURRENT_WORK_RULE));
    vec![ContextPart {
        id: format!("cmux-{scope}-override"),
        source: format!("cmux-{scope}"),
        label: match scope {
            "project" => "Project guidance (first-turn context)",
            "user" => "User guidance (first-turn context)",
            _ => "cmux guidance (first-turn context)",
        }
        .into(),
        tokens: estimated_tokens(text),
        included: !text.is_empty(),
        editable: true,
        measurement: "estimated".into(),
        source_bytes: Some(text.len() as u64),
        channel: Some("user-context".into()),
        text: Some(text.to_owned()),
    }]
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::ContextOverrides;

    #[test]
    fn inventory_preserves_harness_counts_and_marks_cmux_text_editable() {
        let mut meta: SessionMeta = serde_json::from_value(json!({"schema":"acpmux.session.v1","id":"s","name":"s","harness":"claude","cwd":"/repo","status":"idle","createdAt":0,"updatedAt":0})).unwrap();
        meta.context_breakdown = Some(
            json!({"categories":[{"id":"system_prompt","name":"System prompt","tokens":20,"kind":"used"}],"totalTokens":20,"maxTokens":100}),
        );
        let mut cfg = Config::default();
        cfg.context_overrides.user = Some("read concurrently".into());
        meta.cmux_context = Some(snapshot(&cfg, &meta.cwd));
        let got = inventory(&meta, &cfg);
        assert_eq!(got.total_tokens, 20);
        assert_eq!(got.provider_total_tokens, Some(20));
        assert!(got.parts.iter().any(|p| p.source == "harness" && p.tokens == 20 && !p.editable));
        assert!(got.parts.iter().any(|p| p.source == "cmux-user" && p.editable));
    }

    #[test]
    fn inventory_keeps_snapshot_and_does_not_sum_overlapping_details() {
        let mut meta: SessionMeta = serde_json::from_value(json!({"schema":"acpmux.session.v1","id":"s","name":"s","harness":"codex","cwd":"/repo","status":"idle","createdAt":0,"updatedAt":0})).unwrap();
        let mut cfg = Config::default();
        cfg.context_overrides.user = Some("user text".into());
        cfg.context_overrides.set("project", Some(&meta.cwd), Some("project text".into())).unwrap();
        meta.cmux_context = Some(snapshot(&cfg, &meta.cwd));
        cfg.context_overrides.set("project", Some(&meta.cwd), Some("future text".into())).unwrap();
        meta.context_breakdown = Some(
            json!({"categories":[{"id":"skills","name":"Skills","tokens":10}],"skills":[{"name":"reading","tokens":10}],"totalTokens":10}),
        );
        let got = inventory(&meta, &cfg);
        assert_eq!(got.total_tokens, 10);
        assert_eq!(got.provider_total_tokens, Some(10));
        assert_eq!(got.cmux_tokens, estimated_tokens("project text"));
        assert!(got.parts.iter().any(|p| p.source == "skill" && p.tokens == 10));
        assert!(!got.parts.iter().any(|p| p.source == "cmux-user"));
        assert!(got.parts.iter().any(|p| p.text.as_deref() == Some("project text")));
        assert_eq!(got.overrides.project.as_deref(), Some("future text"));
        // ACP harnesses such as Codex can report aggregate usage without a breakdown.
        meta.context_breakdown = None;
        meta.usage = Some(json!({"used":42,"size":200000}));
        let usage = inventory(&meta, &cfg);
        assert_eq!(usage.provider_total_tokens, Some(42));
        assert_eq!(usage.total_tokens, 42);
        assert_eq!(usage.max_tokens, Some(200000));
        assert!(usage.parts.iter().any(|p| p.measurement == "unavailable"));
    }

    #[test]
    fn override_block_is_hidden_context_and_has_approximate_tokens() {
        let mut cfg = Config::default();
        cfg.context_overrides.user = Some("read concurrently".into());
        let captured = snapshot(&cfg, Path::new("/repo"));
        let mut blocks = vec![json!({"type":"text", "text":"user words"})];
        append_snapshot(Some(&captured), &mut blocks);
        assert_eq!(blocks.len(), 2);
        let block = &blocks[1];
        assert!(crate::prompt_context::is_context(block));
        assert!(crate::prompt_context::is_context_text(block["text"].as_str().unwrap()));
        assert_eq!(estimated_tokens("12345678"), 2);
    }

    #[test]
    fn project_override_uses_one_key_for_lexical_and_symlink_paths() {
        let dir = cmux_unix_socket::short_test_dir("context-project-key");
        let cwd = dir.path();
        let lexical = cwd.join(".");
        let mut overrides = ContextOverrides::default();
        overrides.set("project", Some(cwd), Some("project text".into())).unwrap();
        assert_eq!(overrides.for_project(&lexical), Some(("project", "project text")));
        #[cfg(unix)]
        {
            let link = cwd.join("link");
            std::os::unix::fs::symlink(cwd, &link).unwrap();
            assert_eq!(overrides.for_project(&link), Some(("project", "project text")));
        }
    }

    #[test]
    fn new_sessions_capture_default_guidance_and_empty_text_disables_it() {
        let cfg = Config::default();
        let captured = snapshot(&cfg, Path::new("/repo"));
        assert_eq!(captured.len(), 1);
        assert_eq!(captured[0].source, "cmux-default");
        assert!(captured[0].included);
        assert_eq!(captured[0].text.as_deref(), Some(crate::agent_tools::CONCURRENT_WORK_RULE));
        let mut blocks = Vec::new();
        append_snapshot(Some(&captured), &mut blocks);
        assert_eq!(blocks.len(), 1);
        assert_eq!(captured[0].channel.as_deref(), Some("user-context"));
        assert!(
            blocks[0]["text"].as_str().unwrap().contains(crate::agent_tools::CONCURRENT_WORK_RULE)
        );

        let mut disabled = Config::default();
        disabled.context_overrides.user = Some(String::new());
        let captured = snapshot(&disabled, Path::new("/repo"));
        assert_eq!(captured[0].source, "cmux-user");
        assert!(!captured[0].included);
        assert_eq!(captured[0].text.as_deref(), Some(""));
        let mut blocks = Vec::new();
        append_snapshot(Some(&captured), &mut blocks);
        assert!(blocks.is_empty());
    }

    #[test]
    fn chat_guidance_is_its_own_first_turn_block_beside_a_persons_override() {
        let mut cfg = Config::default();
        cfg.context_overrides.user = Some("my rule".into());
        let mut parts = snapshot(&cfg, Path::new("/repo"));
        parts.push(guidance_part(crate::agent_guidance::AGENT_GUIDANCE.into()));
        let mut blocks = Vec::new();
        append_snapshot(Some(&parts), &mut blocks);
        assert_eq!(blocks.len(), 2, "{blocks:?}");
        let text = blocks[1]["text"].as_str().unwrap();
        assert!(text.starts_with("<cmux-guidance-context>") && text.contains("update_plan"), "{text}");
        assert_eq!(blocks[1]["_meta"]["acpmux"]["contextSource"], "cmux-guidance");
        assert!(blocks[0]["text"].as_str().unwrap().contains("my rule"));
    }

    #[test]
    fn overrides_choose_project_over_user_and_clear() {
        let mut overrides = ContextOverrides { user: Some("u".into()), ..Default::default() };
        let cwd = Path::new("/repo");
        overrides.set("project", Some(cwd), Some("p".into())).unwrap();
        assert_eq!(overrides.for_project(cwd), Some(("project", "p")));
        overrides.set("project", Some(cwd), None).unwrap();
        assert_eq!(overrides.for_project(cwd), Some(("user", "u")));
    }
    #[test]
    fn tool_source_snapshots_are_replaced_without_reinjecting_or_replacing_guidance() {
        let mut meta: SessionMeta = serde_json::from_value(json!({"schema":"acpmux.session.v1","id":"s","name":"s","harness":"claude","cwd":"/repo","status":"idle","createdAt":0,"updatedAt":0})).unwrap();
        let mut cfg = Config::default();
        cfg.context_overrides.user = Some("read concurrently".into());
        meta.cmux_context = Some(snapshot(&cfg, &meta.cwd));
        let mut description = meta.cmux_context.as_ref().unwrap()[0].clone();
        description.id = "cmux-source-skill-example".into();
        description.source = "cmux-skill-listing".into();
        description.editable = false;
        description.text = Some("name: example\ndescription: skill listing only".into());
        description.channel = Some("skill-listing".into());
        record_tool_sources(&mut meta, vec![description.clone()]);
        record_tool_sources(&mut meta, vec![description]);
        let snapshot = meta.cmux_context.as_deref().unwrap();
        assert_eq!(snapshot.len(), 2);
        let mut blocks = Vec::new();
        append_snapshot(Some(snapshot), &mut blocks);
        assert_eq!(blocks.len(), 1);
        assert!(blocks[0]["text"].as_str().unwrap().contains("read concurrently"));
        record_tool_sources(&mut meta, Vec::new());
        assert_eq!(meta.cmux_context.as_ref().unwrap().len(), 1);
    }

    #[test]
    fn preset_context_follows_actual_launch_file_after_edits_and_removal() {
        let mut meta: SessionMeta = serde_json::from_value(json!({"schema":"acpmux.session.v1","id":"s","name":"s","harness":"claude","cwd":"/repo","status":"idle","createdAt":0,"updatedAt":0})).unwrap();
        let dir =
            std::env::temp_dir().join(format!("context-source-preset-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("prompt.md");
        let argv =
            vec!["claude".into(), "--system-prompt-file".into(), path.to_string_lossy().into()];
        std::fs::write(&path, "first preset").unwrap();
        record_preset_source(&mut meta, preset_source(&argv));
        assert_eq!(meta.cmux_context.as_ref().unwrap()[0].text.as_deref(), Some("first preset"));
        // A settings/file edit alone cannot change what the current launch received.
        std::fs::write(&path, "next preset").unwrap();
        assert_eq!(meta.cmux_context.as_ref().unwrap()[0].text.as_deref(), Some("first preset"));
        record_preset_source(&mut meta, preset_source(&argv));
        assert_eq!(meta.cmux_context.as_ref().unwrap()[0].text.as_deref(), Some("next preset"));
        record_preset_source(&mut meta, preset_source(&["claude".into()]));
        assert!(meta.cmux_context.as_ref().unwrap().is_empty());
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
