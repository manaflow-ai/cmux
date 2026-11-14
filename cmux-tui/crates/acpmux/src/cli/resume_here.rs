//! `acpmux resume-here SESSION`: the terminal half of Toggle Terminal and Chat for a chat no
//! terminal runs. It shows the chat's running turn as plain text (as `acpmux attach --plain`),
//! asks the daemon to hand the conversation over (`_acpmux/release_to_watch`, answered once the
//! chat is idle: the turn is never cut off), then becomes the harness's own resume command in
//! this terminal. The chat goes on as a watch of this terminal's transcript.

use crate::client::Client;
use crate::rpc::method;
use anyhow::{Result, anyhow};
use serde_json::{Value, json};
use std::sync::Arc;

/// The resume command a release answered: `{argv, cwd, env}`.
#[derive(Debug, PartialEq)]
pub(crate) struct Resume {
    pub argv: Vec<String>,
    pub cwd: Option<String>,
    pub env: Vec<(String, String)>,
}

impl Resume {
    pub(crate) fn from_answer(answer: &Value) -> Result<Self> {
        let r = answer.get("resume").ok_or_else(|| anyhow!("the daemon sent no resume command"))?;
        let argv: Vec<String> = r
            .get("argv")
            .and_then(Value::as_array)
            .map(|a| a.iter().filter_map(Value::as_str).map(str::to_owned).collect())
            .unwrap_or_default();
        if argv.is_empty() {
            return Err(anyhow!("the daemon sent an empty resume command"));
        }
        let cwd = r.get("cwd").and_then(Value::as_str).map(str::to_owned);
        let env = r
            .get("env")
            .and_then(Value::as_object)
            .map(|m| {
                m.iter()
                    .filter_map(|(k, v)| v.as_str().map(|v| (k.clone(), v.to_owned())))
                    .collect()
            })
            .unwrap_or_default();
        Ok(Self { argv, cwd, env })
    }

    /// The command as one shell line.
    pub(crate) fn line(&self) -> String {
        let quote = |w: &str| {
            let safe = !w.is_empty()
                && w.chars().all(|c| c.is_ascii_alphanumeric() || "-_.:@/+=".contains(c));
            if safe { w.to_owned() } else { format!("'{}'", w.replace('\'', "'\\''")) }
        };
        let env = self.env.iter().map(|(k, v)| format!("{k}={}", quote(v)));
        env.chain(self.argv.iter().map(|w| quote(w))).collect::<Vec<_>>().join(" ")
    }
}

pub async fn run(client: Arc<Client>, key: &str, print: bool, json_out: bool) -> Result<()> {
    let id = crate::cli::run::resolve_id(&client, key).await?;
    // The turn shows while it runs; the release answers once it ended.
    let release = client.request(method::MUX_RELEASE_TO_WATCH, json!({"sessionId": id}));
    let answer = if print {
        release.await
    } else {
        // Both on this task: the stream ends when the release answers (it is dropped then).
        let shown = crate::cli::output::plain_attach(client.clone(), &id);
        tokio::pin!(release, shown);
        let answer = tokio::select! {
            answer = &mut release => answer,
            // The stream ended first (a closed connection, a mesh read): wait for the answer alone.
            _ = &mut shown => release.await,
        };
        println!();
        answer
    };
    let resume = Resume::from_answer(&answer?)?;
    if print {
        if json_out {
            let env: serde_json::Map<_, _> =
                resume.env.iter().map(|(k, v)| (k.clone(), json!(v))).collect();
            println!("{}", json!({"argv": resume.argv, "cwd": resume.cwd, "env": env}));
        } else {
            println!("{}", resume.line());
        }
        return Ok(());
    }
    exec(&resume)
}

#[cfg(unix)]
fn exec(resume: &Resume) -> Result<()> {
    use std::os::unix::process::CommandExt as _;
    let mut cmd = std::process::Command::new(&resume.argv[0]);
    cmd.args(&resume.argv[1..]);
    if let Some(cwd) = resume.cwd.as_deref().filter(|c| std::path::Path::new(c).is_dir()) {
        cmd.current_dir(cwd);
    }
    for (k, v) in &resume.env {
        cmd.env(k, v);
    }
    // Only returns on failure.
    let error = cmd.exec();
    Err(anyhow!("could not run `{}`: {error}", resume.line()))
}

#[cfg(not(unix))]
fn exec(resume: &Resume) -> Result<()> {
    Err(anyhow!("run `{}` in this terminal", resume.line()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_answer_becomes_the_harness_command() {
        let answer = json!({"resume": {"argv": ["claude", "--resume", "a b"], "cwd": "/tmp",
            "env": {"CLAUDE_CONFIG_DIR": "/h/.claude"}}});
        let r = Resume::from_answer(&answer).unwrap();
        assert_eq!(r.argv, ["claude", "--resume", "a b"]);
        assert_eq!(r.cwd.as_deref(), Some("/tmp"));
        assert_eq!(r.line(), "CLAUDE_CONFIG_DIR=/h/.claude claude --resume 'a b'");
        assert!(Resume::from_answer(&json!({"resume": {"argv": []}})).is_err());
    }
}
