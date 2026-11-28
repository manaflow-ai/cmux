use super::*;
use serde_json::json;

#[test]
fn reads_both_settings_nested_or_flat_and_skips_bad_entries() {
    let doc = json!({
        "agents": {"env": {"FOO": "1", "bad name": "x", "NUM": 3}},
        "agents.envExclude": ["AWS_*", "SECRET", "*", "1BAD", "SECRET", 4]
    });
    let got = AgentEnv::from_doc(&doc);
    assert_eq!(got.set, BTreeMap::from([("FOO".to_owned(), "1".to_owned())]));
    assert_eq!(got.exclude, ["AWS_*", "SECRET"]);
    assert_eq!(AgentEnv::from_doc(&json!({})), AgentEnv::default());
}

#[test]
fn set_fills_only_what_is_unset_and_never_a_remote_chat() {
    let settings = AgentEnv {
        set: BTreeMap::from([
            ("A".to_owned(), "settings".to_owned()),
            ("B".to_owned(), "settings".to_owned()),
            ("C".to_owned(), "settings".to_owned()),
        ]),
        exclude: vec!["X_*".to_owned()],
    };
    let mut env = BTreeMap::from([("A".to_owned(), "profile".to_owned())]);
    let login = |k: &str| (k == "B").then(|| "login".to_owned());
    settings.apply(&mut env, false, &login);
    assert_eq!(env["A"], "profile");
    assert!(!env.contains_key("B"), "the login shell's value is the agent's");
    assert_eq!(env["C"], "settings");
    assert_eq!(env[EXCLUDE_MARKER], "X_*");

    let mut remote = BTreeMap::new();
    settings.apply(&mut remote, true, &|_| None);
    assert_eq!(remote, BTreeMap::from([(EXCLUDE_MARKER.to_owned(), "X_*".to_owned())]));

    let mut stale = BTreeMap::from([(EXCLUDE_MARKER.to_owned(), "OLD".to_owned())]);
    AgentEnv::default().apply(&mut stale, false, &|_| None);
    assert!(stale.is_empty(), "no exclude list leaves no marker");
}

#[test]
fn exclude_matches_names_and_prefixes_but_never_acpmux_wiring() {
    let p = patterns("AWS_*, SECRET,bad name,ACPMUX_*,CMUX_*");
    assert_eq!(p, ["AWS_*", "SECRET", "ACPMUX_*", "CMUX_*"]);
    assert!(excluded("AWS_SECRET_ACCESS_KEY", &p));
    assert!(excluded("SECRET", &p));
    assert!(!excluded("SECRET_2", &p));
    assert!(!excluded("ACPMUX_SOCKET", &p));
    assert!(!excluded(crate::agent_tools::AGENT_SESSION_ENV, &p));
    for key in crate::person_tokens::CALLER_ENV_KEYS {
        assert!(!excluded(key, &p), "{key}");
    }
    assert!(excluded("CMUX_OTHER", &p));
}
