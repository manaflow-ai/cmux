use super::*;
use crate::agent_tools::{McpServer, OFF_ENV, SERVERS_ENV};
use std::collections::BTreeMap;

fn tools() -> AgentTools {
    AgentTools {
        servers: ["cmux", "cmux-cua"]
            .into_iter()
            .map(|name| McpServer {
                name: name.into(),
                command: "/private/bin/tool".into(),
                args: vec!["serve".into()],
                env: vec![("PRIVATE_TOKEN".into(), "do-not-copy-this-value".into())],
            })
            .collect(),
        plugin_dir: Some("/private/plugin".into()),
        user_plugin_dir: None,
        displays: None,
    }
}

#[test]
fn context_sources_match_the_emitted_mcp_base_and_mode() {
    for all in [false, true] {
        let parts = tools().listing(all).context_parts(false);
        let base = parts.iter().find(|p| p.id == "cmux-source-mcp-base").unwrap();
        let expected = if all { BASE_INSTRUCTIONS } else { CODE_MODE_INSTRUCTIONS };
        let expected = format!("{expected} {ASKING_RULE}");
        assert_eq!(base.text.as_deref(), Some(expected.as_str()));
        assert_eq!(base.tokens, estimated_tokens(&expected));
        assert_eq!(base.source_bytes, Some(expected.len() as u64));
        assert_eq!(base.channel.as_deref(), Some("mcp-instructions"));
        assert!(base.included && !base.editable);
        assert_eq!(base.measurement, "estimated");
        assert_eq!(
            parts
                .iter()
                .filter(|p| p.text.as_deref().is_some_and(|s| s.contains(ASKING_RULE)))
                .count(),
            1
        );
    }
    let mut allowed = tools();
    allowed.servers[0].env.push((MCP_TOOLS_ENV.into(), "agents_snapshot".into()));
    let base = allowed.context_parts(false).remove(0);
    assert_eq!(base.text, Some(format!("{BASE_INSTRUCTIONS} {ASKING_RULE}")));
    assert!(base.label.contains("filtered tool listing"));
}

#[test]
fn context_sources_respect_scope_disabled_servers_and_cua_version() {
    let scoped = tools().scoped(&BTreeMap::from([(SERVERS_ENV.into(), "cmux".into())]));
    assert!(!scoped.context_parts(false).iter().any(|p| p.id == "cmux-source-cua-rule"));
    let off = tools().without_off(&BTreeMap::from([(OFF_ENV.into(), "cmux".into())]));
    assert!(!off.context_parts(false).iter().any(|p| p.id == "cmux-source-mcp-base"));
    assert!(!off.context_parts(false).iter().any(|p| p.id == "cmux-source-cua-rule"));
    let mut bridge = tools();
    bridge.servers[1].env.push((crate::cua_v2::ENDPOINT_DIR_ENV.into(), "/endpoint".into()));
    assert!(!bridge.context_parts(false).iter().any(|p| p.id == "cmux-source-cua-rule"));
    let cue = tools().context_parts(false);
    let cue = cue.iter().find(|p| p.id == "cmux-source-cua-rule").unwrap();
    assert_eq!(cue.text.as_deref(), Some(CUA_RULES));
    assert!(!cue.included); // The runtime decides whether this fragment is loaded.
}

#[test]
fn context_sources_keep_compiled_skill_descriptions_without_bodies_or_credentials() {
    let parts = tools().context_parts(true);
    let skills: Vec<_> = parts.iter().filter(|p| p.source == "cmux-skill-listing").collect();
    let compiled = SKILL_FILES.iter().filter(|(p, _)| p.ends_with("/SKILL.md")).count();
    // No `cmux-secrets` server here, so no `cmux-sudo` listing (`SKILL_SERVERS`).
    assert_eq!(skills.len(), compiled - 1);
    assert!(!skills.iter().any(|p| p.id.ends_with("skill-cmux-cmux-sudo")), "{skills:?}");
    assert!(skills.iter().any(|p| p.id.ends_with("skill-cmux-cmux-cua")), "{skills:?}");
    assert!(skills.iter().any(|p| p.id.ends_with("skill-cmux-cmux-chat")), "{skills:?}");
    for skill in &skills {
        let text = skill.text.as_deref().unwrap();
        assert!(text.starts_with("name:"));
        assert!(text.contains("\ndescription:"));
        assert!(!text.contains("\n# "));
        assert!(skill.label.contains("/SKILL.md"));
        assert!(!skill.editable);
    }
    let serialized = serde_json::to_string(&parts).unwrap();
    assert!(!serialized.contains("do-not-copy-this-value"));
    assert!(!serialized.contains("/private/"));
    assert!(!serialized.contains("inputSchema"));
    assert!(parts.iter().any(|p| p.source == "cmux-hook" && p.measurement == "unavailable"));
    assert!(!tools().context_parts(false).iter().any(|p| p.source == "cmux-skill-listing"));
    let mut no_plugin = tools();
    no_plugin.plugin_dir = None;
    assert!(!no_plugin.context_parts(true).iter().any(|p| p.source == "cmux-skill-listing"));
    assert!(AgentTools::default().context_parts(true).is_empty());
    let mut meta: crate::store::SessionMeta = serde_json::from_value(serde_json::json!({
        "schema":"acpmux.session.v1", "id":"s", "name":"s", "harness":"claude",
        "cwd":"/repo", "status":"idle", "createdAt":0, "updatedAt":0
    }))
    .unwrap();
    let cfg = crate::config::Config::default();
    let inspectable = |meta: &crate::store::SessionMeta| {
        crate::context_inventory::inventory(meta, &cfg)
            .parts
            .iter()
            .filter(|p| p.id.starts_with("cmux-source-") && p.text.is_some())
            .count()
    };
    let before = inspectable(&meta);
    crate::context_inventory::record_tool_sources(&mut meta, parts.clone());
    let after = inspectable(&meta);
    // The skill descriptions plus the two rule fragments (asking, computer use).
    assert_eq!((before, after), (0, skills.len() + 2));
    println!(
        "context-source-fixture: inspectable_before={before}, inspectable_after={after}, rows={}, text_parts={}, persisted_bytes={}, skill_description_tokens={}, full_skill_body_tokens={}",
        parts.len(),
        parts.iter().filter(|p| p.text.is_some()).count(),
        serialized.len(),
        skills.iter().map(|p| p.tokens).sum::<u64>(),
        SKILL_FILES
            .iter()
            .filter(|(path, _)| path.ends_with("/SKILL.md"))
            .map(|(_, text)| estimated_tokens(text))
            .sum::<u64>()
    );
}
