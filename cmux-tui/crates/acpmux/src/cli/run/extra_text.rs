//! `acpmux daemon`/`config`/`web` text: the Web UI line and config.json without its tokens, the
//! start-mode lines, `session place-set`, and the session lifecycle report.

use super::*;

/// The `web:` line of `daemon status` and `daemon start`, and what `acpmux web`
/// prints: the Web UI link without its bearer token unless `show_token`
/// (ergo-walk2, 2026-10-25: a terminal, a screen share or a pasted log is no
/// place for it; ergo-walk4, 2026-10-26, for `web --no-open`).
pub(super) fn web_line(url: Option<&str>, show_token: bool) -> String {
    let Some(url) = url else { return "-".into() };
    if show_token {
        return url.to_owned();
    }
    // `#token=` from this build; `?token=` from an older daemon still running.
    match url.split_once("#token=").or_else(|| url.split_once("?token=")) {
        Some((bare, _)) => format!("{bare} (token hidden: add --show-token)"),
        None => url.to_owned(),
    }
}

/// What a hidden token reads as in `daemon config`.
const HIDDEN_TOKEN: &str = "(token hidden: add --show-token)";

/// config.json as `daemon config` prints it: its JSON printed anew (keys
/// sorted) with the bearer tokens in it replaced by [`HIDDEN_TOKEN`]: the
/// listener's `websocket.token`, a peer's `token` and `peerToken`, and the
/// userinfo, query and fragment of a peer's `url` (ergo-walk4, 2026-10-26:
/// "`acpmux daemon config` human output prints websocket.token in full").
/// Never the file's own text: a duplicate key or an escaped spelling keeps a
/// token there that the parsed config no longer shows. A file that is not
/// JSON is named, not printed: it may hold a token all the same.
pub(super) fn config_text_without_tokens(text: &str) -> String {
    let mut value = match serde_json::from_str::<Value>(text) {
        Ok(value) => value,
        Err(e) => {
            return format!(
                "# (not valid JSON: {e}; it may hold tokens: add --show-token to print it)"
            );
        }
    };
    let hide = |slot: Option<&mut Value>| {
        if let Some(slot) = slot
            && slot.as_str().is_some_and(|s| !s.is_empty())
        {
            *slot = Value::String(HIDDEN_TOKEN.into());
        }
    };
    hide(value.pointer_mut("/websocket/token"));
    if let Some(peers) = value.get_mut("peers").and_then(Value::as_object_mut) {
        for peer in peers.values_mut() {
            hide(peer.get_mut("token"));
            hide(peer.get_mut("peerToken"));
            if let Some(url) = peer.get_mut("url")
                && let Some(text) = url.as_str()
            {
                let bare = crate::server::url_without_secrets(text);
                if bare != text {
                    *url = Value::String(format!("{bare} {HIDDEN_TOKEN}"));
                }
            }
        }
    }
    serde_json::to_string_pretty(&value).unwrap_or_else(|_| HIDDEN_TOKEN.into())
}

/// `acpmux config`'s last lines: the permission mode a new chat starts in, as the local daemon
/// answers `_acpmux/start_mode` (what the app's mode picker shows), for the default harness and
/// each harness with its own `permissionMode`. Nothing when no daemon runs.
pub(super) async fn print_start_modes() {
    let Ok(cfg) = Config::load() else { return };
    let Ok(client) = crate::client::Client::connect(&crate::config::socket_path()).await else {
        return;
    };
    let mut names: Vec<Option<String>> = vec![None];
    names.extend(
        cfg.defaults
            .iter()
            .filter(|(_, d)| d.permission_mode.is_some())
            .map(|(k, _)| Some(k.clone())),
    );
    for name in names {
        let Ok(v) = client.request(method::MUX_START_MODE, json!({"harness": name})).await else {
            continue;
        };
        let s = |k: &str| v.get(k).and_then(Value::as_str).unwrap_or("-").to_owned();
        println!(
            "# new {} chats start in: {} ({}, from {})",
            s("harness"),
            s("level"),
            s("modeId"),
            s("source")
        );
    }
    println!("# change: acpmux config --set permissions.default=yolo|standard|ask|default");
}

/// `acpmux session place-set`: `_acpmux/place_set`, `place_undo` or `place_get`, and what each chat
/// answered. A refused or unconfirmed chat ends the command non-zero.
pub(super) async fn place_session(
    args: crate::cli::command::PlaceSessionArgs,
    json_out: bool,
) -> Result<()> {
    use crate::cli::errors::{AppError, Code};
    let client = connect(true).await?;
    let mut ids = Vec::new();
    for s in &args.sessions {
        ids.push(resolve_id(&client, s).await?);
    }
    let v = if args.undo {
        let mut chats = Vec::new();
        for id in &ids {
            let one = client
                .request("_acpmux/place_undo", json!({"sessionId": id, "confirm": args.yes}))
                .await?;
            chats.extend(one["chats"].as_array().cloned().unwrap_or_default());
        }
        json!({"chats": chats})
    } else if args.status {
        client.request("_acpmux/place_get", json!({"sessionIds": ids})).await?
    } else {
        let mut place = match args.mode.as_deref() {
            Some("cloud") => json!({"mode": "cloud"}),
            Some("machine") => {
                let Some(machine) = args.machine.as_deref() else {
                    return Err(AppError::usage("--mode machine needs --machine NAME").into());
                };
                json!({"mode": "machine", "machine": machine})
            }
            _ => json!({"mode": "auto"}),
        };
        if let Some(cwd) = &args.cwd {
            cmux_json::JsonSet::set(&mut place, "cwd", json!(cwd));
        }
        let mut params = json!({"sessionIds": ids, "place": place, "confirm": args.yes});
        if let Some(why) = &args.why {
            cmux_json::JsonSet::set(&mut params, "why", json!(why));
        }
        client.request("_acpmux/place_set", params).await?
    };
    let chats = v["chats"].as_array().cloned().unwrap_or_default();
    if json_out {
        print_json(&v);
    } else {
        for c in &chats {
            let reason = c["reason"].as_str().map(|r| format!(": {r}")).unwrap_or_default();
            println!(
                "{}: {}{reason}",
                c["sessionId"].as_str().unwrap_or("?"),
                c["state"].as_str().unwrap_or("?")
            );
            for l in c["leftBehind"].as_array().into_iter().flatten() {
                println!("  stays here: {}", l["detail"].as_str().unwrap_or("?"));
            }
            if c["state"] == "needs_confirm" {
                println!("  pass --yes to move anyway");
            }
        }
    }
    let bad =
        chats.iter().find(|c| matches!(c["state"].as_str(), Some("refused" | "needs_confirm")));
    match bad {
        Some(c) if c["state"] == "refused" => Err(AppError::new(
            Code::Refused,
            "place_refused",
            c["reason"].as_str().unwrap_or("refused"),
        )
        .into()),
        Some(_) => Err(AppError::new(
            Code::Refused,
            "place_needs_confirm",
            "the move leaves things behind: nothing moved; pass --yes to move anyway",
        )
        .into()),
        None => Ok(()),
    }
}

/// The text form of a session lifecycle report.
pub(super) fn print_lifecycle_report(v: &Value) {
    let num = |key: &str| v.get(key).and_then(Value::as_u64).unwrap_or(0);
    let flag = |key: &str| v.get(key).and_then(Value::as_bool) == Some(true);
    let mb = |key: &str| num(key) as f64 / 1_048_576.0;
    println!(
        "{} chats {} ({} offloaded{}), {:.1} MB to {:.1} MB, {:.1} MB freed",
        num("archived"),
        if flag("dryRun") { "would be archived (dry run)" } else { "archived" },
        num("offloaded"),
        if flag("cloud") { "" } else { "; cloud history not set up" },
        mb("bytesBefore"),
        mb("bytesAfter"),
        mb("bytesFreed"),
    );
    for chat in v.get("chats").and_then(Value::as_array).into_iter().flatten() {
        let text = |key: &str| chat.get(key).and_then(Value::as_str).unwrap_or("");
        let id = text("id");
        println!(
            "  {}  {}  {}",
            if id.is_empty() { "?" } else { id },
            text("reason"),
            text("name"),
        );
    }
    println!("skipped: {}", v.get("skipped").unwrap_or(&Value::Null));
}
