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
fn a_remote_viewer_gets_counts_but_no_local_paths_or_cmux_text() {
    let mut meta: SessionMeta = serde_json::from_value(json!({"schema":"acpmux.session.v1","id":"s","name":"s","harness":"claude","cwd":"/Users/me/repo","status":"idle","createdAt":0,"updatedAt":0})).unwrap();
    meta.context_breakdown = Some(json!({
        "categories":[{"id":"memory","name":"Memory files","tokens":30,"kind":"used"}],
        "memoryFiles":[{"path":"/Users/me/.claude/CLAUDE.md","tokens":30}],
        "totalTokens":30,"maxTokens":100
    }));
    let mut cfg = Config::default();
    cfg.context_overrides.user = Some("read concurrently".into());
    meta.cmux_context = Some(snapshot(&cfg, &meta.cwd));
    let mut got = inventory(&meta, &cfg);
    redact_for_remote(&mut got);
    let memory = got.parts.iter().find(|p| p.source == "memory").expect("memory part");
    assert_eq!(memory.tokens, 30);
    assert_eq!(memory.label, "CLAUDE.md");
    let wire = serde_json::to_string(&got).unwrap();
    assert!(!wire.contains("/Users/me"), "a local path reached a remote viewer: {wire}");
    assert!(!wire.contains("read concurrently"), "cmux text reached a remote viewer: {wire}");
    assert!(!got.can_edit_overrides);
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
    assert!(blocks[0]["text"].as_str().unwrap().contains(crate::agent_tools::CONCURRENT_WORK_RULE));

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
    let dir = std::env::temp_dir().join(format!("context-source-preset-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("prompt.md");
    let argv = vec!["claude".into(), "--system-prompt-file".into(), path.to_string_lossy().into()];
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

fn profile(json: Value) -> crate::config::HarnessProfile {
    serde_json::from_value(json).unwrap()
}

fn rules_on(channel: &str) -> Vec<ContextPart> {
    let mut parts = snapshot_on(&Config::default(), Path::new("/repo"), channel);
    parts.push(guidance_part_on(crate::agent_guidance::CLAUDE_GUIDANCE.into(), channel));
    parts
}

#[test]
fn claude_gets_the_rules_in_its_system_prompt_and_none_after_the_prompt() {
    let claude = profile(json!({"kind":"claude-stdio","argv":["claude"]}));
    let mut cfg = Config::default();
    cfg.harnesses.insert("claude".into(), claude.clone());
    assert_eq!(rules_channel(&cfg, Path::new("/repo"), "claude"), APPEND_SYSTEM_PROMPT);
    let parts = rules_on(APPEND_SYSTEM_PROMPT);
    assert!(parts.iter().all(|p| p.label.ends_with("(system prompt)")), "{parts:?}");
    let mut blocks = vec![json!({"type":"text","text":"my words"})];
    append_snapshot(Some(&parts), &mut blocks);
    assert_eq!(blocks, vec![json!({"type":"text","text":"my words"})]);
    let want = format!(
        "{}\n\n{}",
        crate::agent_tools::CONCURRENT_WORK_RULE,
        crate::agent_guidance::CLAUDE_GUIDANCE
    );
    assert_eq!(
        launch_args(Some(&parts), &claude, Path::new("/repo")),
        vec!["--append-system-prompt".to_owned(), want]
    );
    // Not a Claude Code command line (the profile changed since): nothing it cannot read.
    let other = profile(json!({"argv":["python3","agent.py"]}));
    assert!(launch_args(Some(&parts), &other, Path::new("/repo")).is_empty());
    // The person's own appended prompt stays theirs, and the rules stay in the first message.
    let own =
        profile(json!({"kind":"claude-stdio","argv":["claude","--append-system-prompt","mine"]}));
    cfg.harnesses.insert("claude".into(), own.clone());
    assert_eq!(rules_channel(&cfg, Path::new("/repo"), "claude"), USER_CONTEXT);
    assert!(launch_args(Some(&parts), &own, Path::new("/repo")).is_empty());
}

#[test]
fn codex_gets_the_rules_as_developer_instructions_unless_it_has_its_own() {
    let home = tempfile::tempdir().unwrap();
    let codex = profile(json!({"argv":["codex","app-server"],
            "env":{"CODEX_HOME": home.path().to_string_lossy()}}));
    let mut cfg = Config::default();
    cfg.harnesses.insert("codex".into(), codex.clone());
    assert_eq!(rules_channel(&cfg, home.path(), "codex"), DEVELOPER_INSTRUCTIONS);
    let parts = rules_on(DEVELOPER_INSTRUCTIONS);
    let mut blocks = Vec::new();
    append_snapshot(Some(&parts), &mut blocks);
    assert!(blocks.is_empty(), "{blocks:?}");
    let args = launch_args(Some(&parts), &codex, home.path());
    assert_eq!(args[0], "-c");
    // Codex parses the value as TOML: it reads back as the rules, quotes and newlines intact.
    let table: toml::Table = args[1].parse().unwrap();
    let text = table["developer_instructions"].as_str().unwrap();
    assert!(text.starts_with(crate::agent_tools::CONCURRENT_WORK_RULE), "{text}");
    assert!(text.ends_with(crate::agent_guidance::CLAUDE_GUIDANCE), "{text}");
    let mut argv = codex.argv.clone();
    argv.extend(args);
    assert!(crate::codex_app_server::is_profile_launch(&argv), "{argv:?}");
    // The start carried them: nothing is owed to a message.
    let mut blocks = Vec::new();
    assert!(!append_owed_rules(Some(&parts), Some(argv.as_slice()), &mut blocks), "{blocks:?}");
    // The person's own developer instructions are never replaced, nor read into cmux's
    // value (a project's config may not be one Codex trusts): a new chat keeps the first
    // message, and a start that finds theirs (its real `CODEX_HOME`) carries no rules and
    // owes them to the next message.
    std::fs::write(home.path().join("config.toml"), "developer_instructions = \"mine\"\n").unwrap();
    assert_eq!(rules_channel(&cfg, home.path(), "codex"), USER_CONTEXT);
    assert!(launch_args(Some(&parts), &codex, home.path()).is_empty());
    assert!(append_owed_rules(Some(&parts), Some(codex.argv.as_slice()), &mut blocks));
    assert_eq!(blocks.len(), 2, "{blocks:?}");
    assert!(blocks[0]["text"].as_str().unwrap().starts_with("<cmux-default-context>"));
    // A moved chat's start (no command line recorded): owed too.
    let mut blocks = Vec::new();
    assert!(append_owed_rules(Some(&parts), None, &mut blocks));
    // Codex's compact `-ckey=value` form counts as their own too.
    let mut compact = codex.clone();
    std::fs::remove_file(home.path().join("config.toml")).unwrap();
    compact.argv.push("-cdeveloper_instructions=\"mine\"".into());
    cfg.harnesses.insert("codex".into(), compact.clone());
    assert_eq!(rules_channel(&cfg, home.path(), "codex"), USER_CONTEXT);
    assert!(launch_args(Some(&parts), &compact, home.path()).is_empty());
    // Any other ACP agent: the first message.
    cfg.harnesses.insert("fake".into(), profile(json!({"argv":["python3","agent.py"]})));
    assert_eq!(rules_channel(&cfg, Path::new("/repo"), "fake"), USER_CONTEXT);
    let parts = rules_on(USER_CONTEXT);
    assert!(parts.iter().all(|p| p.label.ends_with("(first-turn context)")), "{parts:?}");
    let mut blocks = vec![json!({"type":"text","text":"my words"})];
    append_snapshot(Some(&parts), &mut blocks);
    assert_eq!(blocks.len(), 3);
    assert_eq!(blocks[0]["text"], "my words");
    assert!(blocks[1]["text"].as_str().unwrap().starts_with("<cmux-default-context>"));
    assert!(launch_args(Some(&parts), &codex, home.path()).is_empty());
}

#[test]
fn rules_too_long_for_one_launch_argument_stay_in_the_first_message() {
    let mut cfg = Config::default();
    cfg.harnesses
        .insert("claude".into(), profile(json!({"kind":"claude-stdio","argv":["claude"]})));
    cfg.context_overrides.user = Some("x".repeat(MAX_LAUNCH_RULES_BYTES + 1));
    let parts = snapshot_for(&cfg, Path::new("/repo"), "claude", false);
    assert!(parts.iter().all(|p| p.channel.as_deref() == Some(USER_CONTEXT)), "{parts:?}");
    let mut blocks = vec![json!({"type":"text","text":"my words"})];
    append_snapshot(Some(&parts), &mut blocks);
    assert!(blocks.len() >= 2, "{blocks:?}");
    assert!(launch_args(Some(&parts), &cfg.harnesses["claude"], Path::new("/repo")).is_empty());
}

#[test]
fn a_switched_off_rule_reaches_no_channel() {
    let claude = profile(json!({"kind":"claude-stdio","argv":["claude"]}));
    let mut cfg = Config::default();
    cfg.context_overrides.user = Some(String::new());
    let parts = snapshot_on(&cfg, Path::new("/repo"), APPEND_SYSTEM_PROMPT);
    assert!(!parts[0].included);
    assert!(launch_args(Some(&parts), &claude, Path::new("/repo")).is_empty());
    let mut blocks = Vec::new();
    append_snapshot(Some(&parts), &mut blocks);
    assert!(blocks.is_empty());
}

#[test]
fn a_fork_keeps_the_rules_only_when_cut_after_the_turn_that_carried_them() {
    let mut meta: SessionMeta = serde_json::from_value(json!({"schema":"acpmux.session.v1","id":"s","name":"s","harness":"claude","cwd":"/repo","status":"idle","createdAt":0,"updatedAt":0})).unwrap();
    assert!(!fork_keeps_rules(meta.cmux_rules_in_transcript, meta.cmux_rules_seq, 100));
    record_rules_in_transcript(&mut meta, 40);
    // A later message does not move where they entered.
    record_rules_in_transcript(&mut meta, 90);
    assert_eq!(meta.cmux_rules_seq, Some(40));
    assert!(fork_keeps_rules(meta.cmux_rules_in_transcript, meta.cmux_rules_seq, 100));
    assert!(fork_keeps_rules(meta.cmux_rules_in_transcript, meta.cmux_rules_seq, 40));
    // Cut through an earlier turn: its transcript has neither the rules nor their record.
    assert!(!fork_keeps_rules(meta.cmux_rules_in_transcript, meta.cmux_rules_seq, 39));
    // Recorded before the seq was kept: kept, as before.
    meta.cmux_rules_seq = None;
    assert!(fork_keeps_rules(meta.cmux_rules_in_transcript, meta.cmux_rules_seq, 0));
}
