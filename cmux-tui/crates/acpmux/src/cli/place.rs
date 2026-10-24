//! `acpmux host place [--build]` and `new --host auto` (`auto-build` for a
//! build): the daemon's pick from `_acpmux/place` (`server/place.rs`), and
//! why, one line per host.

use crate::client::Client;
use crate::rpc::method;
use anyhow::{Result, bail};
use serde_json::{Value, json};

/// The work `--host` names: `auto` an agent lane, `auto-build` a build; any
/// other value is a host, not a placement.
pub fn auto_work(host: Option<&str>) -> Option<&'static str> {
    match host {
        Some("auto") => Some("agent"),
        Some("auto-build") => Some("build"),
        _ => None,
    }
}

/// The host `new --host auto` creates on: the one already running a session
/// of that name, else the daemon's pick. `None` is this machine. A running
/// session is used only with `--reuse`, as for `new -n`; without it this
/// says where it runs instead of making a second one elsewhere. Prints the
/// pick and why to stderr.
pub async fn resolve(
    client: &Client,
    work: &str,
    name: Option<&str>,
    reuse: bool,
) -> Result<Option<String>> {
    if let Some(name) = name
        && let Ok(v) = client.request(method::MUX_INFO, json!({"sessionId": name})).await
        && v.get("name").and_then(Value::as_str) == Some(name)
    {
        let host = v.get("peer").and_then(Value::as_str).map(str::to_owned);
        if !reuse {
            bail!("{}", running(name, host.as_deref()));
        }
        return Ok(host);
    }
    let v = client.request("_acpmux/place", json!({"work": work})).await?;
    let why = v.get("why").and_then(Value::as_str).unwrap_or_default();
    let Some(pick) = v.get("pick").and_then(Value::as_str) else {
        bail!("{why}");
    };
    eprintln!("placed on {why}");
    Ok((v.get("local").and_then(Value::as_bool) != Some(true)).then(|| pick.to_owned()))
}

/// Why `new --host auto -n NAME` without `--reuse` stops: NAME already runs.
fn running(name: &str, host: Option<&str>) -> String {
    let at = host.map_or_else(|| "this machine".to_owned(), str::to_owned);
    format!("session {name:?} already runs on {at}; add --reuse to use it, or pick another -n")
}

/// `host place`'s lines: the pick, then each host with its room or refusal.
pub fn lines(v: &Value) -> Vec<String> {
    let mut out = vec![match v.get("pick").and_then(Value::as_str) {
        Some(_) => format!("pick {}", v.get("why").and_then(Value::as_str).unwrap_or_default()),
        None => v.get("why").and_then(Value::as_str).unwrap_or("no pick").to_owned(),
    }];
    for h in v.get("hosts").and_then(Value::as_array).into_iter().flatten() {
        let name = h.get("name").and_then(Value::as_str).unwrap_or("?");
        let label = if h.get("local").and_then(Value::as_bool) == Some(true) {
            format!("{name} (this)")
        } else {
            name.to_owned()
        };
        let why = h.get("why").and_then(Value::as_str).unwrap_or_default();
        let line = match h.get("refused").and_then(Value::as_str) {
            Some(r) if why.is_empty() => format!("  {label:<20} refused  {r}"),
            Some(r) => format!("  {label:<20} refused  {r} ({why})"),
            None => format!("  {label:<20} ok       {why}"),
        };
        out.push(line);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn host_place_prints_the_pick_then_each_hosts_room_or_refusal() {
        let v = json!({"pick": "big", "why": "big: 60 GB RAM free, room for 13", "hosts": [
            {"name": "laptop", "local": true, "refused": "no builds here (lanes.build is false)",
             "why": "14 GB RAM free, room for 3"},
            {"name": "big", "local": false, "refused": null, "why": "60 GB RAM free, room for 13"},
            {"name": "mini", "local": false, "refused": "not a lane host", "why": ""},
        ]});
        assert_eq!(
            lines(&v),
            [
                "pick big: 60 GB RAM free, room for 13",
                "  laptop (this)        refused  no builds here (lanes.build is false) (14 GB RAM free, room for 3)",
                "  big                  ok       60 GB RAM free, room for 13",
                "  mini                 refused  not a lane host",
            ]
        );
        assert_eq!(auto_work(Some("auto")), Some("agent"));
        assert_eq!(auto_work(Some("auto-build")), Some("build"));
        assert_eq!(auto_work(Some("huge-blue")), None);
    }
}
