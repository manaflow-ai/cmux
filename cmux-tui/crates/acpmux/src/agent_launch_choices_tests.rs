use super::*;
use serde_json::json;

const SOURCE: &str = include_str!("../../../../schemas/settings/source/agent-defaults.json");

fn words(w: &[&str]) -> Vec<String> {
    w.iter().map(|s| (*s).to_owned()).collect()
}

fn choices(pairs: &[(&str, &str)]) -> LaunchChoices {
    LaunchChoices::parse(|key| pairs.iter().find(|(k, _)| *k == key).map(|(_, v)| (*v).to_owned()))
}

fn row(key: &str) -> Value {
    let doc: Value = serde_json::from_str(SOURCE).unwrap();
    doc["lists"]
        .as_array()
        .unwrap()
        .iter()
        .flat_map(|l| l["rows"].as_array().unwrap().iter())
        .find(|r| r["key"] == key)
        .unwrap_or_else(|| panic!("{key} in agent-defaults.json"))
        .clone()
}

/// The inline `--settings` of `argv`, parsed.
fn inline_settings(argv: &[String]) -> Value {
    let at = argv.iter().rposition(|a| a == "--settings").expect("--settings");
    serde_json::from_str(&argv[at + 1]).unwrap()
}

#[test]
fn the_settings_source_matches_the_daemon() {
    for key in [OUTPUT_STYLE_SETTING, PERSONALITY_SETTING, ATTRIBUTION_SETTING] {
        let row = row(key);
        assert_eq!(row["default"], json!(AGENT_OWN), "{key}: unset keeps the agent's own");
        let values: Vec<&str> = row["choices"]
            .as_array()
            .unwrap()
            .iter()
            .map(|c| c["value"].as_str().unwrap())
            .collect();
        assert_eq!(values[0], AGENT_OWN, "{key}");
        for value in &values[1..] {
            let parsed = choices(&[(key, value)]);
            assert_ne!(parsed, LaunchChoices::default(), "{key}={value} passes something");
        }
    }
    let mut personalities: Vec<String> = row(PERSONALITY_SETTING)["choices"]
        .as_array()
        .unwrap()
        .iter()
        .skip(1)
        .map(|c| c["value"].as_str().unwrap().to_owned())
        .collect();
    personalities.sort();
    let mut accepted = CODEX_PERSONALITIES;
    accepted.sort_unstable();
    assert_eq!(personalities, accepted);
}

#[test]
fn unset_or_agent_passes_nothing() {
    let mut argv = words(&["claude", "--output-format", "stream-json"]);
    let before = argv.clone();
    for c in
        [choices(&[]), choices(&[(OUTPUT_STYLE_SETTING, "agent"), (ATTRIBUTION_SETTING, "agent")])]
    {
        apply_claude(&mut argv, Path::new("/"), &c);
        assert_eq!(argv, before);
    }
    let mut codex = words(&["codex", "app-server"]);
    apply_codex(&mut codex, &choices(&[(PERSONALITY_SETTING, "agent")]));
    assert_eq!(codex, words(&["codex", "app-server"]));
}

#[test]
fn claude_gets_its_output_style_and_stripped_attribution() {
    let c = choices(&[(OUTPUT_STYLE_SETTING, "Explanatory"), (ATTRIBUTION_SETTING, "strip")]);
    let mut argv = words(&["claude", "--output-format", "stream-json"]);
    apply_claude(&mut argv, Path::new("/"), &c);
    assert_eq!(argv[..3], words(&["claude", "--output-format", "stream-json"]));
    assert_eq!(
        inline_settings(&argv),
        json!({"outputStyle": "Explanatory", "attribution": {"commit": "", "pr": ""}})
    );
}

#[test]
fn claude_merges_into_the_launchs_one_settings_and_its_own_keys_win() {
    let c = choices(&[(OUTPUT_STYLE_SETTING, "Learning"), (ATTRIBUTION_SETTING, "strip")]);
    let mut argv = words(&[
        "claude",
        "--settings",
        r#"{"env":{"A":"1"},"includeCoAuthoredBy":true}"#,
        "--model",
        "opus",
        "--",
        "--settings",
        "literal",
    ]);
    apply_claude(&mut argv, Path::new("/"), &c);
    // One --settings before `--`; the positional words after it stay.
    assert_eq!(argv.iter().filter(|a| *a == "--settings").count(), 2, "{argv:?}");
    let dash = argv.iter().position(|a| a == "--").unwrap();
    assert_eq!(argv[dash..], words(&["--", "--settings", "literal"]));
    assert_eq!(argv[dash - 2], "--settings");
    let settings: Value = serde_json::from_str(&argv[dash - 1]).unwrap();
    assert_eq!(
        settings,
        json!({"env": {"A": "1"}, "includeCoAuthoredBy": true, "outputStyle": "Learning"})
    );
    assert_eq!(argv[..3], words(&["claude", "--model", "opus"]));

    // A launch whose settings name both keys is left alone.
    let own = words(&["claude", r#"--settings={"outputStyle":"x","attribution":{"commit":"c"}}"#]);
    let mut same = own.clone();
    apply_claude(&mut same, Path::new("/"), &c);
    assert_eq!(same, own);
}

#[test]
fn claude_settings_that_do_not_read_are_left_alone() {
    let c = choices(&[(OUTPUT_STYLE_SETTING, "Explanatory")]);
    let bad = words(&["claude", "--settings", "/nonexistent/acpmux-settings.json"]);
    let mut argv = bad.clone();
    apply_claude(&mut argv, Path::new("/"), &c);
    assert_eq!(argv, bad);
}

#[test]
fn claude_reads_a_settings_file_relative_to_the_cwd() {
    let dir = std::env::temp_dir().join(format!("acpmux-launch-choices-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("s.json"), r#"{"theme":"dark"}"#).unwrap();
    let mut argv = words(&["claude", "--settings", "s.json"]);
    apply_claude(&mut argv, &dir, &choices(&[(ATTRIBUTION_SETTING, "strip")]));
    assert_eq!(
        inline_settings(&argv),
        json!({"theme": "dark", "attribution": {"commit": "", "pr": ""}})
    );
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn codex_gets_its_personality_unless_the_launch_sets_one() {
    let c = choices(&[(PERSONALITY_SETTING, "pragmatic")]);
    let mut argv = words(&["codex", "app-server"]);
    apply_codex(&mut argv, &c);
    assert_eq!(argv, words(&["codex", "app-server", "-c", "personality=\"pragmatic\""]));
    let own = words(&["codex", "-c", "personality=\"friendly\"", "app-server"]);
    let mut same = own.clone();
    apply_codex(&mut same, &c);
    assert_eq!(same, own);
    // A value codex would refuse is never passed.
    let mut argv = words(&["codex", "app-server"]);
    apply_codex(&mut argv, &choices(&[(PERSONALITY_SETTING, "cheerful")]));
    assert_eq!(argv, words(&["codex", "app-server"]));
}

#[test]
fn attribution_has_no_codex_config() {
    let c = choices(&[(ATTRIBUTION_SETTING, "strip")]);
    let mut argv = words(&["codex", "app-server"]);
    apply_codex(&mut argv, &c);
    assert_eq!(argv, words(&["codex", "app-server"]));
}
