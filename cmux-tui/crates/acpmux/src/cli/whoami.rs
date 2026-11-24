//! `acpmux whoami`: the acpmux identity of the session this shell runs in, as a peer sees it.
//!
//! Leo, 2026-11-21: "what do other agents see you as in acpmux? and how do they send messages to
//! you? ... you dont have a proper name for yourself/metadata labelling yourself to communicate
//! with." An agent that wants to tell a peer how to reply had no command that answered it: `acpmux
//! send`'s `sending as` line is the shell's own claim (a Claude desktop chat's reads "Claude Code
//! desktop on HOST · 03214b87 (a name it gave, not proven)", spaces and all, which no `send`
//! takes), and `resolve @` needs `ACPMUX_SESSION_ID`, which a chat acpmux did not start lacks.
//!
//! The shell's session is found by the id its harness exports: `ACPMUX_SESSION_ID` in a session
//! acpmux runs, else `CLAUDE_CODE_SESSION_ID` (a Claude Code chat: the desktop app's Code tab, a
//! terminal `claude`), else `CODEX_THREAD_ID` (a Codex thread). The answer is the daemon's record
//! (`resolve`): its name, handle, tags, and whether its address works now, never what this shell
//! claims. A chat with no record, or a registration a restart left stale, says the one command
//! that fixes it.

use anyhow::Result;
use serde_json::{Value, json};

use crate::cli::output::print_json;
use crate::rpc::method;

/// What the shell's environment names it by.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Me {
    /// An acpmux session (its mux id).
    Session(String),
    /// A Claude Code chat acpmux did not start (its Claude session id).
    Claude(String),
    /// A Codex thread (its thread id).
    Codex(String),
}

impl Me {
    fn key(&self) -> &str {
        match self {
            Self::Session(k) | Self::Claude(k) | Self::Codex(k) => k,
        }
    }
}

/// The session `env` names, the acpmux one first.
pub(crate) fn me_in(env: impl Fn(&str) -> Option<String>) -> Option<Me> {
    let set = |key: &str| env(key).map(|v| v.trim().to_owned()).filter(|v| !v.is_empty());
    if crate::cli::sender::in_session(&env) {
        return set("ACPMUX_SESSION_ID").map(Me::Session);
    }
    if set("CLAUDECODE").is_some() {
        return set("CLAUDE_CODE_SESSION_ID").map(Me::Claude);
    }
    set("CODEX_THREAD_ID").map(Me::Codex)
}

/// The card of `matches` that is this shell's own session: on this machine, by its ids.
fn mine<'a>(me: &Me, matches: &'a [Value]) -> Option<&'a Value> {
    let key = me.key();
    let local = |s: &&Value| s["peer"].is_null();
    let ids = |s: &&Value| {
        s["sessionId"] == key || s["agentSessionId"] == key || s["qualifiedSessionId"] == key
    };
    let live = |s: &&Value| s["status"] != "closed";
    matches
        .iter()
        .filter(local)
        .filter(ids)
        .max_by_key(|s| (live(s), s["updatedAt"].as_u64().unwrap_or(0)))
}

/// Whoami's answer for `me` from its card (`None`: the daemon has none), on `host`.
pub(crate) fn answer(me: &Me, card: Option<&Value>, host: &str) -> Value {
    let program = crate::cli::entry::program();
    let Some(s) = card else {
        let (state, fix) = match me {
            Me::Session(_) => ("unknown", format!("`{program} session restart @`")),
            Me::Claude(_) => (
                "unregistered",
                format!(
                    "`{program} register --auto` in this chat's Bash tool (or `{program} register NAME`), then the `--code` line it delivers"
                ),
            ),
            Me::Codex(_) => (
                "unreachable",
                format!(
                    "a Codex desktop thread cannot register (nothing ties a shell to its thread): turn on `{}` with `codex_desktop` in `{}`, or start Codex with `{program} new -m codex`",
                    crate::claude_peers::ENABLED_KEY,
                    crate::claude_peers::ENTRYPOINTS_KEY
                ),
            ),
        };
        return json!({
            "host": host, "name": null, "state": state, "reach": null,
            "id": me.key(), "fix": fix,
        });
    };
    let text = |k: &str| s[k].as_str().unwrap_or_default().to_owned();
    let host = Some(text("host")).filter(|h| !h.is_empty()).unwrap_or_else(|| host.to_owned());
    let name = text("name");
    let tags = s["tags"].clone();
    let tag = |k: &str| tags[k].as_str().map(str::to_owned);
    let registered = tag(crate::hub::register::REGISTERED_TAG).as_deref() == Some("true");
    let (state, fix) = if let Some(why) = tag("bridge.unreachable") {
        let fix = format!("`{program} register {name}` in this chat's Bash tool ({why})");
        ("stale", Some(fix))
    } else if matches!(me, Me::Session(_)) {
        ("proven", None)
    } else if registered {
        ("registered", None)
    } else {
        ("bridged", None)
    };
    let reach = format!("{program} send {host}/{name} '...'");
    json!({
        "host": host,
        "name": name,
        "handle": s["handle"],
        "alias": tag("session.alias"),
        "state": state,
        "reach": reach,
        "reachHere": format!("{program} send {name} '...'"),
        "sessionId": s["qualifiedSessionId"],
        "harness": s["harness"],
        "agentSessionId": s["agentSessionId"],
        "tags": tags,
        "fix": fix,
    })
}

/// The lines `acpmux whoami` prints for `v` ([`answer`]).
pub(crate) fn text(v: &Value) -> String {
    let field = |k: &str| v[k].as_str().unwrap_or_default().to_owned();
    let mut out = String::new();
    let mut row = |label: &str, value: String| {
        if !value.is_empty() {
            out.push_str(&format!("{label:<8} {value}\n"));
        }
    };
    if v["name"].is_null() {
        row("name", format!("none: peers cannot reach this session ({})", field("state")));
        row("machine", field("host"));
        row("id", field("id"));
        row("fix", field("fix"));
        return out;
    }
    row("name", field("name"));
    let alias = v["alias"].as_str().map(|a| format!("  (spoken: {a})")).unwrap_or_default();
    row("handle", format!("{}{alias}", field("handle")));
    row("machine", field("host"));
    row(
        "session",
        format!("{}  ({} {})", field("sessionId"), field("harness"), field("agentSessionId")),
    );
    let tags: Vec<String> = v["tags"]
        .as_object()
        .into_iter()
        .flatten()
        .filter(|(k, _)| k.as_str() != "bridge.unreachable")
        .map(|(k, v)| format!("{k}={}", v.as_str().map_or_else(|| v.to_string(), str::to_owned)))
        .collect();
    row("tags", tags.join(" "));
    let state = match field("state").as_str() {
        "proven" => "proven: this daemon issued this session's caller token".to_owned(),
        "registered" => "registered: `acpmux register` proved this chat's process".to_owned(),
        "bridged" => "bridged: the desktop bridge lists this chat".to_owned(),
        "stale" => "STALE: peers' messages queue until this chat registers again".to_owned(),
        other => other.to_owned(),
    };
    row("address", state);
    row("reach", format!("{}   (on this machine: {})", field("reach"), field("reachHere")));
    row("fix", field("fix"));
    out
}

pub async fn run(json_out: bool) -> Result<()> {
    let host = crate::host_pressure::host_name();
    let Some(me) = me_in(|key| std::env::var(key).ok()) else {
        anyhow::bail!(
            "whoami: this shell runs in no agent session acpmux can name (no ACPMUX_SESSION_ID, CLAUDE_CODE_SESSION_ID or CODEX_THREAD_ID)"
        );
    };
    let client = crate::daemon::connect(true).await?;
    let reply = client.request(method::MUX_RESOLVE, json!({"query": me.key()})).await;
    // A chat the daemon has no record of is an answer, not an error.
    let matches = reply.ok().and_then(|r| r["matches"].as_array().cloned()).unwrap_or_default();
    let v = answer(&me, mine(&me, &matches), &host);
    if json_out {
        print_json(&v);
    } else {
        print!("{}", text(&v));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env<'a>(pairs: &'a [(&'a str, &'a str)]) -> impl Fn(&str) -> Option<String> + 'a {
        move |key| pairs.iter().find(|(k, _)| *k == key).map(|(_, v)| (*v).to_owned())
    }

    #[test]
    fn the_shell_names_its_session_by_its_harness_id() {
        let desktop = [("CLAUDECODE", "1"), ("CLAUDE_CODE_SESSION_ID", "03214b87-953d")];
        assert_eq!(me_in(env(&desktop)), Some(Me::Claude("03214b87-953d".into())));
        assert_eq!(me_in(env(&[("CODEX_THREAD_ID", "t1")])), Some(Me::Codex("t1".into())));
        let lane = [
            ("CLAUDECODE", "1"),
            ("CLAUDE_CODE_SESSION_ID", "c1"),
            ("ACPMUX_SESSION_ID", "m1"),
            (crate::hub::person::CALLER_TOKEN_ENV, "tok"),
        ];
        assert_eq!(me_in(env(&lane)), Some(Me::Session("m1".into())), "acpmux's own id wins");
        assert_eq!(me_in(env(&[])), None);
    }

    /// Repro (Leo, 2026-11-21): the desktop chat on cosmic-gray had no command that said how a
    /// peer reaches it. Its card now names `desktop-leo` and the send that reaches it, and a
    /// registration a restart left stale says so with the command that fixes it.
    #[test]
    fn a_registered_desktop_chat_says_its_name_and_how_peers_reach_it() {
        let me = Me::Claude("03214b87-953d".into());
        let card = json!({
            "name": "desktop-leo", "handle": "Bun-f0ea72ca0005", "host": "cosmic-gray",
            "peer": null, "status": "idle", "sessionId": "01a1", "agentSessionId": "03214b87-953d",
            "qualifiedSessionId": "local/01a1", "harness": "claude",
            "tags": {"bridge": "claude", "bridge.registered": "true", "origin": "claude-desktop",
                     "role": "desktop", "person": "leo", "session.alias": "Harper dot desktop-leo"},
        });
        let other =
            json!({"name": "hb/desktop-leo", "peer": "hb", "agentSessionId": "03214b87-953d"});
        let matches = [other, card.clone()];
        let found = mine(&me, &matches);
        assert_eq!(found, Some(&card), "the card on this machine");
        let v = answer(&me, found, "cosmic-gray");
        assert_eq!(v["state"], "registered");
        let program = crate::cli::entry::program();
        assert_eq!(v["reach"], format!("{program} send cosmic-gray/desktop-leo '...'"));
        let shown = text(&v);
        assert!(shown.starts_with("name     desktop-leo\n"), "{shown}");
        assert!(shown.contains("(spoken: Harper dot desktop-leo)"), "{shown}");
        assert!(shown.contains("person=leo"), "{shown}");
        assert!(shown.contains("role=desktop"), "{shown}");

        let mut stale = card.clone();
        stale["tags"]["bridge.unreachable"] = json!("registration stale: Claude Code restarted");
        let v = answer(&me, Some(&stale), "cosmic-gray");
        assert_eq!(v["state"], "stale");
        assert!(v["fix"].as_str().unwrap().contains("register desktop-leo"), "{v}");
        assert!(text(&v).contains("STALE"), "{}", text(&v));
    }

    #[test]
    fn a_chat_with_no_record_says_how_to_get_an_address() {
        let v = answer(&Me::Claude("c1".into()), None, "cosmic-gray");
        assert_eq!(v["state"], "unregistered");
        assert!(v["fix"].as_str().unwrap().contains("register --auto"), "{v}");
        assert!(text(&v).starts_with("name     none: peers cannot reach"), "{}", text(&v));
        let v = answer(&Me::Codex("t1".into()), None, "cosmic-gray");
        assert_eq!(v["state"], "unreachable");
        assert!(v["fix"].as_str().unwrap().contains("codex_desktop"), "{v}");
    }
}
