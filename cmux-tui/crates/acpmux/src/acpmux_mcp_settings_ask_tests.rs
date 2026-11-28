use super::*;

#[test]
fn github_targets_name_an_org_or_a_repository() {
    assert_eq!(
        check(&json!({"target": "connection:github"})).unwrap(),
        json!({"kind": "connection", "provider": "github"})
    );
    assert_eq!(
        check(&json!({"target": "connection:github:manaflow-ai", "why": " Push needs it. "}))
            .unwrap(),
        json!({"kind": "connection", "provider": "github", "org": "manaflow-ai", "why": "Push needs it."})
    );
    assert_eq!(
        check(&json!({"connection": "github:manaflow-ai/cmux"})).unwrap(),
        json!({"kind": "connection", "provider": "github", "org": "manaflow-ai", "repo": "manaflow-ai/cmux"})
    );
    assert_eq!(check(&json!({"target": "GitHub"})).unwrap()["provider"], "github");
}

#[test]
fn other_targets_and_bad_names_are_refused_with_the_way_on() {
    for bad in [
        json!({}),
        json!({"target": "setting:app theme"}),
        json!({"target": "ftp://settings/x"}),
        json!({"target": "connection:github:-bad-"}),
        json!({"target": "connection:github:a/.."}),
    ] {
        let e = check(&bad).unwrap_err();
        assert!(e.contains("connection:github"), "{bad}: {e}");
    }
}

#[test]
fn a_setting_comes_back_as_its_link() {
    assert_eq!(
        check(&json!({"target": "setting:terminal/terminal.fontSize", "why": "Bigger text"}))
            .unwrap(),
        json!({"kind": "link", "link": "cmux://settings/terminal/terminal.fontSize", "why": "Bigger text"})
    );
    assert_eq!(
        check(&json!({"setting": "Settings: models > add"})).unwrap()["link"],
        "cmux://settings/models/add"
    );
    assert_eq!(
        check(&json!({"target": "cmux-nightly://settings/cloud/claude"})).unwrap()["link"],
        "cmux://settings/cloud/claude"
    );
    assert_eq!(
        check(&json!({"target": "cmux://settings"})).unwrap()["link"],
        "cmux://settings"
    );
    let said = call(&json!({"target": "setting:accounts/machines"}));
    assert_eq!(said["isError"], false);
    assert!(said.to_string().contains("cmux://settings/accounts/machines"), "{said}");
}

#[test]
fn a_long_why_is_cut_never_refused() {
    let why = "x".repeat(400);
    let got = check(&json!({"target": "github", "why": why})).unwrap();
    assert_eq!(got["why"].as_str().unwrap().chars().count(), MAX_WHY);
    assert_eq!(call(&json!({"target": "github:manaflow-ai"}))["isError"], false);
}
