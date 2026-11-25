use super::*;

#[test]
fn any_launcher_agent_env_drops_cmux_tui_claude_plugins_and_keeps_the_rest() {
    let root = tempfile::tempdir().unwrap();
    // A build's plugin folder, deleted with its build: found by its place.
    let build = root.path().join("data/cmux-tui/builds/0123abcd/claude-plugin");
    // A cmux-tui plugin somewhere else: found by its manifest.
    let named = root.path().join("elsewhere");
    std::fs::create_dir_all(named.join(".claude-plugin")).unwrap();
    std::fs::write(named.join(MANIFEST), r#"{"name": "cmux-tui"}"#).unwrap();
    // The person's own plugins stay, one of them in a folder of the same name.
    let mine = root.path().join("tools/claude-plugin");
    let other = root.path().join("other");
    std::fs::create_dir_all(other.join(".claude-plugin")).unwrap();
    std::fs::write(other.join(MANIFEST), r#"{"name": "my-plugin"}"#).unwrap();
    let value = std::env::join_paths([&build, &mine, &named, &other]).unwrap();
    let kept = without_cmux_tui_plugins(&value).unwrap();
    assert_eq!(std::env::split_paths(&kept).collect::<Vec<_>>(), [mine, other]);
    let only_cmux = std::env::join_paths([&build, &named]).unwrap();
    assert_eq!(without_cmux_tui_plugins(&only_cmux), None);
}
