use super::*;

#[test]
fn a_provider_other_than_openai_is_a_way_in() {
    assert!(names_openai("model_provider=\"openai\""));
    assert!(names_openai("model_provider = 'openai'"));
    assert!(!names_openai("model_provider=\"subrouter\""));
    let dir = std::env::temp_dir().join(format!("acpmux-codex-signed-out-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("config.toml");
    std::fs::write(&path, "model_provider = \"subrouter\"\n").unwrap();
    assert!(config_names_provider(&path));
    std::fs::write(&path, "model_provider = \"openai\"\n").unwrap();
    assert!(!config_names_provider(&path));
    std::fs::write(&path, "[profiles.x]\nmodel_provider = \"subrouter\"\n").unwrap();
    assert!(!config_names_provider(&path), "only the top level counts");
    let _ = std::fs::remove_dir_all(&dir);
}
