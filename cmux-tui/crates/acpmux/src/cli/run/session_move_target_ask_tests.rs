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
