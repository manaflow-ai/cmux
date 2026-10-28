//! The ledgers as a pure fold (stub).

/// Applies one event to the ledger state (stub).
pub fn ledger_apply(
    _state_json: &str,
    _event_json: &str,
    _ctx_json: &str,
) -> Result<String, String> {
    Err("not yet".into())
}
