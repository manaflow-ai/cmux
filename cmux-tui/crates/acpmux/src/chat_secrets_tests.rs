use super::*;

fn pair(n: &str, v: &str) -> (String, Zeroizing<String>) {
    (n.to_owned(), Zeroizing::new(v.to_owned()))
}

fn env_of(cmd: &tokio::process::Command, name: &str) -> Option<String> {
    cmd.as_std()
        .get_envs()
        .find(|(k, _)| k.to_str() == Some(name))
        .and_then(|(_, v)| v.map(|v| v.to_string_lossy().into_owned()))
}

#[test]
fn a_chat_secret_reaches_its_own_chat_only_and_expires() {
    let (a, b) = ("chat-secrets-unit-a", "chat-secrets-unit-b");
    set(a, vec![pair("UNIT_TOKEN", "v-a")], None).unwrap();
    let mut own = tokio::process::Command::new("true");
    apply(&mut own, Some(a));
    assert_eq!(env_of(&own, "UNIT_TOKEN").as_deref(), Some("v-a"));
    let mut other = tokio::process::Command::new("true");
    apply(&mut other, Some(b));
    assert_eq!(env_of(&other, "UNIT_TOKEN"), None);
    let mut none = tokio::process::Command::new("true");
    apply(&mut none, None);
    assert_eq!(env_of(&none, "UNIT_TOKEN"), None);
    let listed = list(a);
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].0, "UNIT_TOKEN");
    assert!(listed[0].1 > DEFAULT_TTL.as_secs() - 60);
    assert_eq!(clear(a), 1);
    assert!(list(a).is_empty());

    set(a, vec![pair("UNIT_SHORT", "v")], Some(Duration::from_millis(30))).unwrap();
    std::thread::sleep(Duration::from_millis(60));
    let mut late = tokio::process::Command::new("true");
    apply(&mut late, Some(a));
    assert_eq!(env_of(&late, "UNIT_SHORT"), None);
    assert!(list(a).is_empty());
}

#[test]
fn a_set_refuses_loader_and_cmux_names_bad_values_and_ttls() {
    let s = "chat-secrets-unit-refuse";
    for name in ["PATH", "LD_PRELOAD", "DYLD_INSERT_LIBRARIES", "ACPMUX_HOME", "CMUX_X", "a b"] {
        assert_eq!(set(s, vec![pair(name, "v")], None), Err(Refused::Name(name.to_owned())));
    }
    assert_eq!(set(s, vec![pair("OK_NAME", "")], None), Err(Refused::Value("OK_NAME".into())));
    assert_eq!(set(s, vec![pair("OK_NAME", "a\0b")], None), Err(Refused::Value("OK_NAME".into())));
    assert_eq!(set(s, vec![pair("OK_NAME", "v")], Some(Duration::ZERO)), Err(Refused::Ttl));
    assert_eq!(set(s, vec![pair("OK_NAME", "v")], Some(MAX_TTL * 2)), Err(Refused::Ttl));
    let many = (0..=MAX_NAMES).map(|i| pair(&format!("N{i}"), "v")).collect();
    assert_eq!(set(s, many, None), Err(Refused::TooMany));
    // All or nothing: a refused set left nothing behind.
    assert!(list(s).is_empty());
}
