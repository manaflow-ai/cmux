//! `acpmux allow`, `acpmux deny` and `acpmux answer`: answer a session's
//! pending permission, or the agent question it carries.

use super::*;
use crate::cli::errors::AppError;
use crate::question_answer;

pub(crate) async fn answer_permission(
    session: &str,
    option: Option<String>,
    allow: bool,
    json_out: bool,
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
    let selected_kind = option_id.as_deref().and_then(|id| {
        options
            .iter()
            .find(|o| o.get("optionId").and_then(Value::as_str) == Some(id))
            .and_then(|o| o.get("kind").and_then(Value::as_str))
    });
    client
        .request(
            method::MUX_PERMISSION_RESPOND,
            json!({"sessionId": id, "permissionId": pid, "optionId": option_id.clone()}),
        )
        .await
        .map_err(|e| explain_person_required(e, session))?;
    if json_out {
        print_json(
            &json!({"sessionId": id, "permissionId": pid, "optionId": option_id, "kind": selected_kind}),
        );
    } else {
        println!("{}", if allow { "allowed" } else { "denied" });
    }
    Ok(())
}

/// The daemon allows only from the cmux app (`hub/person.rs`): say so, and
/// what the CLI still can do.
fn explain_person_required(e: anyhow::Error, session: &str) -> anyhow::Error {
    let person = e.downcast_ref::<crate::client::DaemonError>().is_some_and(|d| {
        d.0.data.as_ref().and_then(|v| v.get("reason")).and_then(Value::as_str)
            == Some(crate::hub::person::REASON)
    });
    if !person {
        return e;
    }
    let deny = format!("acpmux deny {session}");
    let mut app = AppError::new(
        crate::cli::errors::Code::Runtime,
        "person_required",
        format!(
            "the CLI cannot allow a permission: only the cmux app may. Approve this in cmux NEXT on the machine whose app shows the chat; `{deny}` still denies it. The prompt is still pending. A session gets its policy when it starts, on the machine that runs it. Only `acpmux new --policy approve-all ...` (for a peer: `ssh HOST 'acpmux new --policy approve-all ... -d'`) runs every tool call without asking, shell commands included; approve-reads and approve-edits still ask before each shell command, and Codex reads files with shell commands, so under them each of those needs an approval in the cmux app."
        ),
    );
    app.data = Some(json!({"reason": crate::hub::person::REASON, "try": deny}));
    app.into()
}

/// `acpmux answer <session> [--answer QUESTION=CHOICE]...`: answers the first
/// pending permission's question with the allow option and the
/// harness-shaped `answers`. With no --answer it prints the questions and
/// the command (exit 2). A person runs this; nothing answers on its own.
pub(crate) async fn answer_question(session: &str, args: &[String], json_out: bool) -> Result<()> {
    let client = connect(true).await?;
    let id = resolve_id(&client, session).await?;
    let info = client.request(method::MUX_INFO, json!({"sessionId": id})).await?;
    let pending = info.get("pending").and_then(Value::as_array).cloned().unwrap_or_default();
    let Some(first) = pending.first() else {
        return Err(anyhow!("no pending permission"));
    };
    let request = first.get("request").unwrap_or(&Value::Null);
    let Some(question) = question_answer::question(request) else {
        let hint = question_answer::pending_hint(request, session);
        return Err(
            AppError::usage(format!("the pending permission is not a question: {hint}")).into()
        );
    };
    if args.is_empty() {
        let mut error = AppError::usage("answer every question with --answer");
        if json_out {
            error.data = Some(json!({"sessionId": id, "question": question.clone()}));
        } else {
            print!("{}", question_answer::usage(question, session));
        }
        return Err(error.into());
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
            json!({"sessionId": id, "permissionId": pid, "optionId": option_id, "answers": answers.clone()}),
        )
        .await
        .map_err(|e| explain_person_required(e, session))?;
    if json_out {
        print_json(
            &json!({"sessionId": id, "permissionId": pid, "answered": true, "answers": answers}),
        );
    } else {
        println!("answered");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn refusal(session: &str) -> String {
        let refused = crate::client::DaemonError(crate::hub::person::person_required(
            "allowing a permission",
        ));
        format!("{:#}", explain_person_required(refused.into(), session))
    }

    /// The refusal of a CLI allow names a policy only when that policy covers
    /// what the agent asks next. Codex sends every command, its reads too, as
    /// `execute`, which approve-reads and approve-edits still ask about, so the
    /// tool prompt after the next start waited again (ergo-walk2, 2026-10-25).
    #[test]
    fn the_allow_refusal_names_no_policy_that_still_asks_for_shell_commands() {
        let text = refusal("my-linux/api-work");
        assert!(!text.contains("--policy approve-edits"), "{text}");
        assert!(!text.contains("--policy approve-reads"), "{text}");
        assert!(text.contains("--policy approve-all"), "{text}");
        assert!(text.contains("shell command"), "{text}");
        assert!(text.contains("in the cmux app"), "{text}");
        assert!(text.contains("`acpmux deny my-linux/api-work`"), "{text}");
        assert!(!text.contains("acpmux session allow"), "{text}");
    }
}
