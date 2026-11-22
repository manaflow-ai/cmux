//! `acpmux send --notice`: a tool's or reconciler's notice (`_meta.acpmux.notice`,
//! `prompt_provenance::notice_of`; manaflow-ai/cmux "notice prompt kind"). The CLI checks it as
//! the daemon will, names its sender as `fromAgent` too (so a daemon that knows no notice still
//! records a named sender's message, never the person's) and sends the rendered text
//! (`prompt_provenance::notice_text`) as the prompt, so the agent and any old page read it.

use cmux_json::JsonSet as _;
use serde_json::{Value, json};

use crate::cli::command::SendNotice;
use crate::cli::errors::AppError;

/// A checked notice: `{sender, host?, severity, title, links?}`.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct Notice(pub Value);

impl Notice {
    pub(crate) fn sender(&self) -> &str {
        self.0.get("sender").and_then(Value::as_str).unwrap_or_default()
    }
}

/// The session name an agent's environment carries (`agent/command.rs`).
const SESSION_NAME_ENV: &str = "ACPMUX_SESSION_NAME";

/// The sender a notice names with no `--sender`: `from` (`--from`), `ACPMUX_FROM`, else the
/// calling session's name.
pub(crate) fn default_sender(
    from: Option<&str>,
    env: impl Fn(&str) -> Option<String>,
) -> Option<String> {
    let set = |v: Option<String>| v.map(|v| v.trim().to_owned()).filter(|v| !v.is_empty());
    set(from.map(str::to_owned))
        .or_else(|| set(env(crate::cli::sender::FROM_ENV)))
        .or_else(|| set(env(SESSION_NAME_ENV)))
}

/// A notice's fields checked as the daemon checks them (`prompt_provenance::notice_of`); its
/// refusal names the field.
pub(crate) fn checked(raw: Value) -> Result<Notice, String> {
    let params = json!({"_meta": {"acpmux": {"notice": raw}}});
    match crate::prompt_provenance::notice_of(&params) {
        Ok(Some(notice)) => Ok(Notice(notice)),
        Ok(None) => Err("notice is empty".to_owned()),
        Err(e) => Err(e.message),
    }
}

/// The notice `acpmux send` sends, from its flags: `None` without `--notice`. `--sender`
/// defaults to [`default_sender`], `--host` to this machine (left out when its name is no host
/// name the daemon takes).
pub(crate) fn of_args(
    args: SendNotice,
    from: Option<&str>,
    env: impl Fn(&str) -> Option<String>,
) -> Result<Option<Notice>, AppError> {
    if !args.notice {
        return Ok(None);
    }
    let sender = args.sender.or_else(|| default_sender(from, &env)).ok_or_else(|| {
        AppError::usage("send --notice needs a sender: --sender NAME, --from NAME or ACPMUX_FROM")
    })?;
    let mut raw = json!({"sender": sender, "severity": args.severity, "title": args.title});
    match args.host {
        Some(host) => {
            raw.set("host", json!(host));
        }
        None => {
            let here = crate::host_pressure::host_name();
            let here = here.strip_suffix(".local").unwrap_or(&here).to_owned();
            if checked(json!({"sender": "x", "severity": "info", "title": "x", "host": here}))
                .is_ok()
            {
                raw.set("host", json!(here));
            }
        }
    }
    if !args.links.is_empty() {
        let links: Vec<Value> =
            args.links.iter().map(|l| crate::prompt_provenance::notice_link(l)).collect();
        raw.set("links", json!(links));
    }
    checked(raw).map(Some).map_err(|e| AppError::usage(format!("send --notice: {e}")))
}

/// The prompt's text: the rendered notice over `body`, or `body` itself for no notice.
pub(crate) fn text(notice: Option<&Notice>, body: &str) -> String {
    match notice {
        Some(notice) => crate::prompt_provenance::notice_text(&notice.0, body),
        None => body.to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env<'a>(pairs: &'a [(&'a str, &'a str)]) -> impl Fn(&str) -> Option<String> + 'a {
        move |key| pairs.iter().find(|(k, _)| *k == key).map(|(_, v)| (*v).to_owned())
    }

    fn args(sender: Option<&str>, host: Option<&str>, links: &[&str]) -> SendNotice {
        SendNotice {
            notice: true,
            severity: Some("fire".into()),
            title: Some("fast tier failed on 3 PRs".into()),
            sender: sender.map(str::to_owned),
            host: host.map(str::to_owned),
            links: links.iter().map(|l| (*l).to_owned()).collect(),
        }
    }

    #[test]
    fn the_sender_is_the_flag_else_from_else_acpmux_from_else_the_sessions_name() {
        let all = [("ACPMUX_FROM", "env-from"), ("ACPMUX_SESSION_NAME", "lane-1")];
        assert_eq!(default_sender(Some("cli-from"), env(&all)).as_deref(), Some("cli-from"));
        assert_eq!(default_sender(None, env(&all)).as_deref(), Some("env-from"));
        let session = [("ACPMUX_SESSION_NAME", "lane-1")];
        assert_eq!(default_sender(None, env(&session)).as_deref(), Some("lane-1"));
        assert_eq!(default_sender(Some("  "), env(&[])), None);
        let given = of_args(args(Some("base-red-watch"), Some("m-3"), &[]), Some("x"), env(&all));
        assert_eq!(given.unwrap().unwrap().sender(), "base-red-watch");
        let named = of_args(args(None, Some("m-3"), &[]), None, env(&session)).unwrap().unwrap();
        assert_eq!(named.sender(), "lane-1");
        assert!(of_args(args(None, Some("m-3"), &[]), None, env(&[])).is_err(), "no sender");
    }

    #[test]
    fn no_notice_flag_is_no_notice_and_bad_fields_are_usage_errors() {
        assert_eq!(of_args(SendNotice::default(), Some("x"), env(&[])).unwrap(), None);
        let bad_link = of_args(args(Some("s"), Some("m"), &["http://x.dev"]), None, env(&[]));
        let message = bad_link.unwrap_err().to_string();
        assert!(message.contains("links.url"), "{message}");
        let bad_host = of_args(args(Some("s"), Some("a b"), &[]), None, env(&[]));
        assert!(bad_host.is_err());
    }

    #[test]
    fn the_cli_renders_the_text_the_model_and_old_pages_read() {
        let notice = of_args(
            args(Some("base-red-watch"), Some("ci-mini-3"), &["https://github.com/o/r/pull/7=#7"]),
            None,
            env(&[]),
        )
        .unwrap()
        .unwrap();
        assert_eq!(
            notice.0,
            json!({"sender": "base-red-watch", "host": "ci-mini-3", "severity": "fire",
                   "title": "fast tier failed on 3 PRs",
                   "links": [{"url": "https://github.com/o/r/pull/7", "label": "#7"}]})
        );
        assert_eq!(
            text(Some(&notice), "red on #7"),
            "[notice from base-red-watch on ci-mini-3 · FIRE] fast tier failed on 3 PRs\n\
             red on #7\nLinks: https://github.com/o/r/pull/7 (#7)"
        );
        assert_eq!(text(None, "plain"), "plain");
        // No --host: this machine, when its name reads as one.
        let here = of_args(args(Some("s"), None, &[]), None, env(&[])).unwrap().unwrap();
        let host = here.0.get("host").and_then(Value::as_str);
        assert!(host.is_none_or(|h| !h.is_empty() && !h.ends_with(".local")), "{here:?}");
    }
}
