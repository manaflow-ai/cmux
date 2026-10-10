//! `acpmux allow`, `acpmux deny` and `acpmux answer`: answer a session's
//! pending permission, or the agent question it carries.

use super::*;
use crate::cli::errors::AppError;
use crate::question_answer;

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

/// `acpmux answer <session> [--answer QUESTION=CHOICE]...`: answers the first
/// pending permission's question with the allow option and the
/// harness-shaped `answers`. With no --answer it prints the questions and
/// the command (exit 2). A person runs this; nothing answers on its own.
pub(crate) async fn answer_question(session: &str, args: &[String]) -> Result<()> {
    let client = connect(true).await?;
    let id = resolve_id(&client, session).await?;
    let info = client.request(method::MUX_INFO, json!({"sessionId": id})).await?;
    let pending = info.get("pending").and_then(Value::as_array).cloned().unwrap_or_default();
    let Some(first) = pending.first() else {
        return Err(anyhow!("no pending permission"));
    };
    let request = first.get("request").unwrap_or(&Value::Null);
    let Some(question) = question_answer::question(request) else {
        return Err(AppError::usage(format!(
            "the pending permission is not a question: use `acpmux allow {session}` or `acpmux deny {session}`"
        ))
        .into());
    };
    if args.is_empty() {
        print!("{}", question_answer::usage(question, session));
        return Err(AppError::usage("answer every question with --answer").into());
    }
    let answers = question_answer::parse_answers(question, args).map_err(AppError::usage)?;
    let option_id = request
        .get("options")
        .and_then(Value::as_array)
        .and_then(|options| {
            let kind =
                |k: &str| options.iter().find(|o| o.get("kind").and_then(Value::as_str) == Some(k));
            kind("allow_once").or_else(|| kind("allow_always"))
        })
        .and_then(|o| o.get("optionId").and_then(Value::as_str))
        .ok_or_else(|| anyhow!("the question offers no allow option"))?;
    let pid = first.get("permissionId").and_then(Value::as_str).unwrap_or("");
    client
        .request(
            method::MUX_PERMISSION_RESPOND,
            json!({"sessionId": id, "permissionId": pid, "optionId": option_id, "answers": answers}),
        )
        .await?;
    println!("answered");
    Ok(())
}
