use super::*;
use crate::rpc::RpcError;

fn daemon(code: i64, message: &str) -> anyhow::Error {
    anyhow::Error::from(crate::client::DaemonError(RpcError::new(code, message)))
}

#[test]
fn the_manifest_names_the_harness_and_the_epoch_the_move_would_carry() {
    let m = manifest("s1", &json!({"harness": "claude-sr2", "ownershipEpoch": 3}));
    assert_eq!(m["schema"], TRANSFER_SCHEMA);
    assert_eq!(m["sessionId"], "s1");
    assert_eq!(m["session"]["harness"], "claude-sr2");
    assert_eq!(m["epoch"], 4);
    let durable = manifest("s2", &json!({"harness": "cmux-harness"}));
    assert_eq!(durable["schema"], DURABLE_TRANSFER_SCHEMA);
    assert!(durable.get("epoch").is_none(), "an unreported epoch is not invented");
}

#[test]
fn an_older_target_is_unasked_and_a_refusal_keeps_the_daemons_code() {
    assert!(unasked(&daemon(-32601, "Method not found: _acpmux/transfer_preflight")));
    let refused = daemon(-32000, "transfer.harness: agent \"x\" is not configured here");
    assert!(!unasked(&refused));
    assert_eq!(refusal_code(&refused), Some("transfer.harness"));
    assert_eq!(
        refusal_code(&daemon(-32000, "transfer.exists: chat s is here already")),
        Some("transfer.exists")
    );
    assert_eq!(refusal_code(&daemon(-32000, "transfer.harnessed: no")), None);
    assert_eq!(refusal_code(&anyhow!("ssh failed")), None);
}

#[test]
fn the_manifest_carries_the_recorded_env_names_and_the_preset_and_the_answer_reads_what_lacks() {
    let info = json!({"harness": "claude", "manifestEnv": {"names": ["OPENAI_API_KEY"], "preset": "fast"}});
    let m = manifest("s1", &info);
    assert_eq!(m["env"], json!(["OPENAI_API_KEY"]));
    assert_eq!(m["preset"], "fast");
    // Nothing recorded, or the manifest off on the source: nothing asked.
    let plain = manifest("s1", &json!({"harness": "claude"}));
    assert!(plain.get("env").is_none() && plain.get("preset").is_none());

    assert_eq!(lacking(&json!({"takes": true, "envLacking": ["OPENAI_API_KEY"]})), ["OPENAI_API_KEY"]);
    // A target older than the question answers no names.
    assert!(lacking(&json!({"takes": true})).is_empty());
    let line = lacking_text("lane", "box", &["A".into(), "B".into()]).unwrap();
    assert!(line.starts_with("lane: box lacks env its agent started with here: A, B"), "{line}");
    assert_eq!(lacking_text("lane", "box", &[]), None);
}
