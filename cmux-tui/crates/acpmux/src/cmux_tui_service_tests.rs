use super::*;

#[tokio::test]
async fn a_pipe_takes_exactly_its_declared_early_bytes() {
    let mut reader: &[u8] = b"hello-world";
    let early = read_early(&mut reader, &json!({"early": 5})).await.unwrap();
    assert_eq!(early, b"hello");
    assert_eq!(reader, b"-world", "the rest is carried after the reply");
    let mut reader: &[u8] = b"untouched";
    assert!(read_early(&mut reader, &json!({})).await.unwrap().is_empty());
    assert_eq!(reader, b"untouched");
    let mut short: &[u8] = b"abc";
    let refused = read_early(&mut short, &json!({"early": 9})).await.unwrap_err();
    assert_eq!(refused.data.as_ref().and_then(|d| d.get("reason")), Some(&json!("pipe.early")));
}

fn consent(required: bool, control: &str) -> Value {
    json!({"consentRequired": required, "consent": {"screen": "none", "control": control}})
}

#[test]
fn a_machine_the_hub_lists_is_named_by_its_host() {
    let machines = vec![
        ("a".repeat(44), "gcp-lane-2".to_owned()),
        ("b".repeat(44), "air".to_owned()),
        ("c".repeat(44), "twice".to_owned()),
        ("d".repeat(44), "Twice".to_owned()),
    ];
    assert_eq!(book_key(&machines, "gcp-lane-2"), Some("a".repeat(44)));
    assert_eq!(book_key(&machines, "AIR"), Some("b".repeat(44)));
    // Two machines listed under one name: neither is picked.
    assert_eq!(book_key(&machines, "twice"), None);
    assert_eq!(book_key(&machines, "nowhere"), None);
}

#[test]
fn no_configured_daemon_admits_nothing() {
    let refused = admit(None, &consent(false, "none"), 7781).unwrap_err();
    assert_eq!(refused.reason, "service.off");
}

#[test]
fn a_joined_machine_needs_control_consent() {
    let refused = admit(Some("127.0.0.1:7781"), &consent(true, "none"), 7781).unwrap_err();
    assert_eq!(refused.reason, crate::cli::cloud_join::CONSENT_REQUIRED);
    // An unreadable consent status counts as required and not granted.
    let refused = admit(Some("127.0.0.1:7781"), &json!({}), 7781).unwrap_err();
    assert_eq!(refused.reason, crate::cli::cloud_join::CONSENT_REQUIRED);
    let address = admit(Some("127.0.0.1:7781"), &consent(true, "granted"), 7781).unwrap();
    assert_eq!(address, "127.0.0.1:7781".parse().unwrap());
}

#[test]
fn only_the_configured_loopback_port_is_reached() {
    let refused = admit(Some("127.0.0.1:7781"), &consent(false, "none"), 22).unwrap_err();
    assert_eq!(refused.reason, "service.port");
    let refused = admit(Some("10.0.0.5:7781"), &consent(false, "none"), 7781).unwrap_err();
    assert_eq!(refused.reason, "service.misconfigured");
    assert!(admit(Some("[::1]:7781"), &consent(false, "none"), 7781).is_ok());
}

#[test]
fn ssh_is_reached_only_when_its_owner_turned_it_on() {
    // Off (the default): port 22 is refused, and the refusal says how to turn it on.
    let refused =
        admit_with(Some("127.0.0.1:7781"), false, &consent(false, "none"), 22).unwrap_err();
    assert_eq!(refused.reason, "service.port");
    assert!(refused.message.contains("remote_pipe.ssh=true"), "{}", refused.message);
    let refused = admit_with(None, false, &consent(false, "none"), 22).unwrap_err();
    assert_eq!(refused.reason, "service.off");
    // On: loopback sshd, beside the remote daemon, whose own port is unchanged.
    let ssh = admit_with(Some("127.0.0.1:7781"), true, &consent(false, "none"), 22).unwrap();
    assert_eq!(ssh, "127.0.0.1:22".parse().unwrap());
    let daemon = admit_with(Some("127.0.0.1:7781"), true, &consent(false, "none"), 7781).unwrap();
    assert_eq!(daemon, "127.0.0.1:7781".parse().unwrap());
    let refused =
        admit_with(Some("127.0.0.1:7781"), true, &consent(false, "none"), 2222).unwrap_err();
    assert_eq!(refused.reason, "service.port");
    // With no remote daemon at all, ssh alone.
    assert!(admit_with(None, true, &consent(false, "none"), 22).is_ok());
    // A joined machine still needs control consent for ssh.
    let refused = admit_with(None, true, &consent(true, "none"), 22).unwrap_err();
    assert_eq!(refused.reason, crate::cli::cloud_join::CONSENT_REQUIRED);
    assert!(admit_with(None, true, &consent(true, "granted"), 22).is_ok());
}

#[test]
fn remote_pipe_ssh_is_set_and_cleared_by_config() {
    let mut config = crate::config::Config::default();
    assert!(!config.remote_pipe.ssh);
    config.set("remote_pipe.ssh", "true").unwrap();
    assert!(config.remote_pipe.ssh);
    let written = serde_json::to_value(&config).unwrap();
    assert_eq!(written.pointer("/remotePipe/ssh"), Some(&json!(true)));
    assert!(config.set("remote-pipe.ssh", "maybe").is_err());
    config.set("remotePipe.ssh", "off").unwrap();
    assert!(!config.remote_pipe.ssh);
    // Off writes nothing: a config that never turned it on is unchanged.
    assert!(serde_json::to_value(&config).unwrap().get("remotePipe").is_none());
}

#[test]
fn config_set_takes_only_a_loopback_address() {
    let mut config = crate::config::Config::default();
    config.set("remote_daemon", "127.0.0.1:7781").unwrap();
    assert_eq!(config.remote_daemon.as_deref(), Some("127.0.0.1:7781"));
    assert!(config.set("remote-daemon", "0.0.0.0:7781").is_err());
    assert!(config.set("remote_daemon", "example.com:7781").is_err());
    config.set("remoteDaemon", "none").unwrap();
    assert_eq!(config.remote_daemon, None);
    // The hub carrier needs no transport: the transport's switch is refused without its
    // static settings (`config/start_check.rs`), and set with them.
    assert!(config.set("transport.wireguard", "true").is_err());
    assert!(!config.transport.wireguard);
    config.transport.wireguard_static = Some(crate::wireguard::StaticConfig {
        listen: "127.0.0.1:0".parse().unwrap(),
        address: "10.77.0.1:4100".parse().unwrap(),
    });
    config.set("transport.wireguard", "true").unwrap();
    assert!(config.transport.wireguard);
    assert!(config.set("transport.wireguard", "maybe").is_err());
}
