use super::*;

const FIXTURE: &str = include_str!("../../tests/fixtures/acp-registry.json");

#[test]
fn add_writes_a_loadable_profile_once() {
    let reg = registry::parse(FIXTURE.as_bytes()).unwrap();
    let dir = std::env::temp_dir().join(format!("acpmux-reg-add-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let sources =
        ProfileSources { user_dir: Some(dir.join("harnesses")), ..ProfileSources::none() };
    let npx = |bin: &str| (bin == "npx").then(|| "/u/bin/npx".to_owned());
    let (id, path) = add(&reg, "github-copilot-cli", false, &sources, &npx).unwrap();
    assert_eq!(id, "github-copilot-cli");
    let loaded = profiles::load(&sources);
    assert!(loaded.diagnostics.is_empty(), "{:?}", loaded.diagnostics);
    assert_eq!(
        loaded.profiles["github-copilot-cli"].0.argv,
        vec!["/u/bin/npx".to_owned(), "-y".into(), "@github/copilot@1.0.93".into(), "--acp".into()]
    );
    assert!(add(&reg, "github-copilot-cli", false, &sources, &npx).is_err());
    assert!(add(&reg, "github-copilot-cli", true, &sources, &npx).is_ok());
    // Known agents keep acpmux's ids.
    assert_eq!(add(&reg, "grok-build", false, &sources, &npx).unwrap().0, "grok");
    // An archive-only agent that is not installed is refused with its page.
    let err = add(&reg, "goose", false, &sources, &npx).unwrap_err().to_string();
    assert!(err.contains("binary archive") || err.contains("cannot start"), "{err}");
    assert!(add(&reg, "nope", false, &sources, &npx).is_err());
    let _ = std::fs::remove_dir_all(&dir);
    let _ = path;
}
