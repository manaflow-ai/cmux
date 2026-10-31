//! `acpmux send --tag TAG MSG`: one `--no-wait` message to every live session that carries a
//! tag, on every host, in place of `acpmux ls --tag … --json | python3` and a loop of sends
//! (ao-cli-audit, 2026-10-30: 14 such loops in 8 transcripts on one lane host). And
//! `session info --fields`: the one value a script wanted, without `--json | python3`.

use super::*;
use crate::cli::select;

/// The sessions a `send --tag` goes to: every one carrying `tag` that is not closed, except the
/// sender's own session, newest first as the daemon lists them. Each is `(target, name)`: a
/// session here by its id, a peer's by its `peer/id` (`qualifiedSessionId`), the key the outbox
/// routes a peer's session by (`Hub::resolve_remote`); its bare id may name nothing here, or
/// another session.
pub(crate) fn tag_targets(
    sessions: &[Value],
    tag: &str,
    own: Option<&str>,
) -> Vec<(String, String)> {
    sessions
        .iter()
        .filter(|s| select::tag_matches(s, tag))
        .filter(|s| s.get("status").and_then(Value::as_str) != Some("closed"))
        .filter_map(|s| {
            let id = s.get("sessionId").and_then(Value::as_str)?;
            // The sender's own id is a session here; a peer's session may carry the same bare id.
            let target = if s.get("peer").and_then(Value::as_str).is_some() {
                s.get("qualifiedSessionId").and_then(Value::as_str)?
            } else if Some(id) == own {
                return None;
            } else {
                id
            };
            let name = s.get("name").and_then(Value::as_str).unwrap_or(id);
            Some((target.to_owned(), name.to_owned()))
        })
        .collect()
}

/// Queue `text` for each session `tag` names. Each send is a `--no-wait` one with its own
/// prompt id; one failure is reported on its line and the rest still go. Exit 1 when any failed,
/// 4 (no such session) when nothing carries the tag.
pub(super) async fn send_to_tag(
    tag: &str,
    text: &str,
    template: &PromptId,
    steer: bool,
    dry_run: bool,
    json_out: bool,
) -> Result<()> {
    let client = connect(true).await?;
    let listed = client.whole_list(method::MUX_SESSIONS, json!({})).await?;
    let sessions = listed.get("sessions").and_then(Value::as_array).cloned().unwrap_or_default();
    let own = std::env::var("ACPMUX_SESSION_ID").ok();
    let targets = tag_targets(&sessions, tag, own.as_deref());
    if targets.is_empty() {
        return Err(errors::AppError::no_session(&format!("--tag {tag}")).into());
    }
    let mut rows = Vec::new();
    let mut failed = 0;
    for (id, name) in &targets {
        if dry_run {
            rows.push(json!({"name": name, "sessionId": id, "status": "dry-run"}));
            continue;
        }
        let mut prompt_id = template.clone();
        prompt_id.id = uuid::Uuid::now_v7().to_string();
        let request = prompt_id.params(id, text, steer, None);
        match client.request(method::MUX_SEND_QUEUE, json!({"request": request})).await {
            Ok(queued) => {
                let delivery = queued.get("deliveryId").and_then(Value::as_str).unwrap_or("");
                rows.push(json!({"name": name, "sessionId": id, "status": "queued", "deliveryId": delivery}));
            }
            Err(error) => {
                failed += 1;
                rows.push(json!({"name": name, "sessionId": id, "status": "failed", "error": error.to_string()}));
            }
        }
    }
    if json_out {
        print_json(&json!({"tag": tag, "sent": rows}));
    } else {
        for row in &rows {
            let g = |k: &str| row.get(k).and_then(Value::as_str).unwrap_or("");
            match g("status") {
                "queued" => {
                    println!("{}\tqueued (acpmux send --status {})", g("name"), g("deliveryId"))
                }
                "dry-run" => println!("{}\twould send", g("name")),
                _ => println!("{}\tfailed: {}", g("name"), g("error")),
            }
        }
    }
    if failed > 0 {
        return Err(anyhow!("{failed} of {} sends failed", targets.len()));
    }
    Ok(())
}

/// `session info --fields`: a single field prints its bare value, several print
/// `field<TAB>value` lines, and --json prints an object of just those fields.
pub(super) fn print_info_fields(info: &Value, fields: &str, json_out: bool) -> Result<()> {
    let fields = select::parse_fields(fields)?;
    if json_out {
        print_json(&select::project_fields(info, &fields));
    } else if let [only] = fields.as_slice() {
        println!("{}", select::text_field(select::field(info, only)));
    } else {
        for path in &fields {
            println!("{path}\t{}", select::text_field(select::field(info, path)));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::tag_targets;
    use serde_json::json;

    #[test]
    fn tag_targets_skip_closed_sessions_other_tags_and_the_sender() {
        let sessions = vec![
            json!({"sessionId": "a", "name": "ao-cli-ls", "status": "running", "tags": {"area": {"value": "acpmux"}}}),
            json!({"sessionId": "b", "name": "ao-old", "status": "closed", "tags": {"area": {"value": "acpmux"}}}),
            json!({"sessionId": "c", "name": "cloud-x", "status": "idle", "tags": {"area": {"value": "cloud"}}}),
            json!({"sessionId": "d", "qualifiedSessionId": "huge-blue/d", "name": "huge-blue/ao-peer", "peer": "huge-blue", "status": "idle", "tags": {"area": "acpmux"}}),
            json!({"sessionId": "e", "name": "huge-blue/no-receipt", "peer": "huge-blue", "status": "idle", "tags": {"area": "acpmux"}}),
            json!({"sessionId": "me", "name": "ao-cli-audit", "status": "running", "tags": {"area": {"value": "acpmux"}}}),
        ];
        // A peer's session with the sender's bare id is another session: it still gets the message.
        let mut twin = sessions.clone();
        twin.push(json!({"sessionId": "me", "qualifiedSessionId": "huge-blue/me", "name": "huge-blue/twin",
                         "peer": "huge-blue", "status": "idle", "tags": {"area": "acpmux"}}));
        let got = tag_targets(&twin, "area=acpmux", Some("me"));
        assert!(got.contains(&("huge-blue/me".to_owned(), "huge-blue/twin".to_owned())), "{got:?}");
        assert!(!got.iter().any(|(target, _)| target == "me"), "{got:?}");
        let got = tag_targets(&sessions, "area=acpmux", Some("me"));
        assert_eq!(
            got,
            vec![
                ("a".to_owned(), "ao-cli-ls".to_owned()),
                ("huge-blue/d".to_owned(), "huge-blue/ao-peer".to_owned())
            ]
        );
        // A peer's session goes by its peer/id; one without that key is skipped, never sent by its
        // bare id (which may name nothing here, or another session).
        assert_eq!(tag_targets(&sessions, "area", None).len(), 4);
    }
}
