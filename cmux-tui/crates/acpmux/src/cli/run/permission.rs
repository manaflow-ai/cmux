//! `acpmux allow` and `acpmux deny`: answer a session's pending permission.

use super::*;

pub(crate) async fn answer_permission(
    session: &str,
    option: Option<String>,
    allow: bool,
) -> Result<()> {
    let client = connect(true).await?;
    let id = resolve_id(&client, session).await?;
    let info = client.request(method::MUX_INFO, json!({"sessionId": id})).await?;
    let pending = info.get("pending").and_then(Value::as_array).cloned().unwrap_or_default();
    let Some(first) = pending.first() else {
        return Err(anyhow!("no pending permission"));
    };
    let pid = first.get("permissionId").and_then(Value::as_str).unwrap_or("").to_owned();
    let options =
        first.pointer("/request/options").and_then(Value::as_array).cloned().unwrap_or_default();
    let pick = |kinds: &[&str]| {
        kinds.iter().find_map(|k| {
            options
                .iter()
                .find(|o| o.get("kind").and_then(Value::as_str) == Some(k))
                .and_then(|o| o.get("optionId").and_then(Value::as_str).map(str::to_owned))
        })
    };
    let option_id = match (option, allow) {
        (Some(o), _) => Some(o),
        (None, true) => pick(&["allow_once", "allow_always"]),
        (None, false) => pick(&["reject_once", "reject_always"]),
    };
    client
        .request(
            method::MUX_PERMISSION_RESPOND,
            json!({"sessionId": id, "permissionId": pid, "optionId": option_id}),
        )
        .await?;
    println!("{}", if allow { "allowed" } else { "denied" });
    Ok(())
}
