//! `acpmux host place [--build]` and `new --host auto` (`auto-build` for a
//! build): the daemon's pick from `_acpmux/place` (`server/place.rs`), and
//! why, one line per host.

use crate::client::Client;
use crate::rpc::method;
use anyhow::{Result, bail};
use cmux_json::JsonSet as _;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

/// The work `--host` names: `auto` an agent lane, `auto-build` a build; any
/// other value is a host, not a placement.
pub fn auto_work(host: Option<&str>) -> Option<&'static str> {
    host.and_then(crate::placement::Work::of_host).map(crate::placement::Work::as_str)
}

/// Where a command-line `new` with `--host` value `host` goes, on a machine the registry marks
/// interactive or not (`placement::interactive`): `Some(work)` to place it (`resolve`), `None`
/// for the host named (`Ok(None)`: this machine). With no `--host` a machine a person works at
/// places an agent lane on a fleet host, so the agents started from its command line run there
/// and not on it (Leo, 2026-10-29, after cosmic-gray beachballed under 94 sessions);
/// `--host local` keeps it here. A `--cwd` or `-w` names a folder on this machine, which a
/// fleet host refuses (`remote_guard.rs`: a peer may use only a known project or its webRoots),
/// so such a launch stays here and says how to place it (`Target::HereForFolder`). The app's
/// own chats never come through here: it creates them over its own connection (`session/new`),
/// so they stay where they were opened.
pub fn new_target(host: Option<&str>, interactive: bool, folder_named: bool) -> Target {
    match host {
        Some("local") => Target::Here,
        None if interactive && folder_named => Target::HereForFolder,
        None if interactive => Target::Place("agent"),
        None => Target::Here,
        Some(h) => match auto_work(Some(h)) {
            Some(work) => Target::Place(work),
            None => Target::Host(h.to_owned()),
        },
    }
}

/// What `new_target` decided.
#[derive(Debug, PartialEq, Eq)]
pub enum Target {
    /// This machine.
    Here,
    /// This machine, a person's, because the launch names a folder on it: warn and say how to
    /// place it (`FOLDER_HERE`).
    HereForFolder,
    /// The peer named.
    Host(String),
    /// The placement's pick for this work (`agent`, `build`).
    Place(&'static str),
}

/// What a `Target::HereForFolder` launch prints.
pub const FOLDER_HERE: &str = "starting on this machine, which a person works at, because --cwd or \
-w names a folder here; leave them out to place it on a fleet host (`acpmux machine pick`), or \
pass --machine local to say this machine on purpose";

/// Whether this machine is one a person works at, by the fleet registry.
pub fn here_is_interactive() -> bool {
    crate::placement::interactive(
        crate::placement::load_registry().as_ref(),
        crate::hub::host_label(),
    )
}

/// The host `new --host auto` creates on: the one already running a session
/// of that name, else the daemon's pick. `None` is this machine. A running
/// session is used only with `--reuse`, as for `new -n`; without it this
/// says where it runs instead of making a second one elsewhere. Prints the
/// pick and why to stderr. A name running on more than one machine is not
/// guessed at: `--host` chooses. `off_interactive` (this machine is one a person works at)
/// leaves every interactive machine out of the pick. `here_if_none` (a `new` that named no
/// host): when that leaves none, the session starts here with a warning, as load and lane caps
/// only warn, unless the registry holds this machine; an explicit `--host auto` still stops.
pub async fn resolve(
    client: &Client,
    work: &str,
    name: Option<&str>,
    reuse: bool,
    off_interactive: bool,
    here_if_none: bool,
) -> Result<Option<String>> {
    if let Some(name) = name {
        let list = client.whole_list(method::MUX_SESSIONS, json!({})).await?;
        match running_on(&list, name).as_slice() {
            [] => {}
            [host] if reuse => return Ok(host.clone()),
            [host] => bail!("{}", running(name, host.as_deref())),
            many => {
                // This machine first, then the peers by name.
                let mut many = many.to_vec();
                many.sort();
                let at: Vec<String> = many.iter().map(|h| at(h.as_deref())).collect();
                bail!("session {name:?} runs on {}; pass --machine with one of them", at.join(", "))
            }
        }
    }
    let mut params = json!({"work": work});
    if off_interactive {
        params.set("offInteractive", json!(true));
    }
    let v = client.request("_acpmux/place", params).await?;
    let registry = crate::placement::load_registry();
    let skipped = match freestyle_turn(&v, registry.as_ref(), work, run_claim).await {
        Freestyle::Claimed(host) => {
            eprintln!("{}", claimed(&host));
            let here = crate::placement::canonical(crate::hub::host_label());
            return Ok((crate::placement::canonical(&host) != here).then_some(host));
        }
        Freestyle::Skipped(why) => Some(why),
        Freestyle::Untouched => None,
    };
    let (Some(pick), Some(placed)) =
        (v.get("pick").and_then(Value::as_str), crate::placement::placed(&v))
    else {
        let held = here_if_none
            .then(|| crate::placement::held(registry.as_ref(), crate::hub::host_label()))
            .flatten();
        return without_pick(&v, here_if_none, held, skipped.as_deref());
    };
    if let Some(why) =
        skipped.as_ref().filter(|_| !crate::placement::is_freestyle(registry.as_ref(), pick))
    {
        eprintln!("{}", freestyle_skipped(why, pick));
    }
    eprintln!("{placed}");
    Ok((v.get("local").and_then(Value::as_bool) != Some(true)).then(|| pick.to_owned()))
}

/// A verdict with no pick: an explicit `--host auto` stops with why; a `new` that named no host
/// (`here_if_none`) starts here with a warning, unless the registry holds this machine (`held`).
/// `skipped`: why the Freestyle claim named no host (`freestyle_turn`), said with the outcome.
fn without_pick(
    v: &Value,
    here_if_none: bool,
    held: Option<String>,
    skipped: Option<&str>,
) -> Result<Option<String>> {
    let why = v.get("why").and_then(Value::as_str).unwrap_or_default();
    let why = match skipped {
        Some(skip) => format!("{why}; freestyle skipped: {skip}"),
        None => why.to_owned(),
    };
    match (here_if_none, held) {
        (false, _) => bail!("{why}"),
        (true, Some(held)) => bail!("{why}; this machine is {held}"),
        (true, None) => {
            if let Some(skip) = skipped {
                eprintln!("{}", freestyle_skipped(skip, "this machine"));
            }
            eprintln!("{}", no_fleet_host(v));
            Ok(None)
        }
    }
}

/// The line auto placement prints when `lane_place.placement_preference` puts freestyle first
/// and the work goes to a host that is not on Freestyle: the same words lane-place prints
/// (leo-workspace `tools/lane_place.py` `FREESTYLE_SKIP`).
pub fn freestyle_skipped(why: &str, chosen: &str) -> String {
    format!("acpmux: freestyle skipped: {why}; placing on {chosen}")
}

/// The line for a host the Freestyle claim named.
fn claimed(host: &str) -> String {
    format!(
        "placed on {host}: the Freestyle claim ({FREESTYLE_PROVIDER}, lane_overflow) named it \
         (lane_place.placement_preference puts freestyle first)"
    )
}

/// The `lane_overflow.providers` entry that claims a Freestyle lane slot.
pub const FREESTYLE_PROVIDER: &str = "freestyle-lanes";

/// The longest `new --host auto` waits for the Freestyle claim, whatever
/// `lane_overflow.timeout_seconds` allows (lane-place's own default bound, `OVERFLOW_TIMEOUT`).
pub const CLAIM_TIMEOUT_CAP: Duration = Duration::from_secs(240);

/// The claim is passed its bound less this as `--budget`, so it answers before it is killed
/// (lane-place's `OVERFLOW_SLACK`).
const CLAIM_SLACK_SECS: u64 = 10;

/// What the Freestyle claim is run as: the provider's argv (its first word resolved against the
/// leo-workspace checkout) with lane-place's flags, and how long it may take before it is killed.
#[derive(Debug, PartialEq, Eq)]
pub struct ClaimAsk {
    pub argv: Vec<String>,
    pub timeout: Duration,
}

/// What the claim answered: the host it named, or the whole WHY of the skip line.
pub type ClaimAnswer = std::result::Result<String, String>;

/// What `freestyle_turn` decided.
#[derive(Debug, PartialEq, Eq)]
pub enum Freestyle {
    /// Freestyle is not first, or the daemon's pick is a Freestyle host with room: as before.
    Untouched,
    /// The claim named this host: the work goes there.
    Claimed(String),
    /// The claim was not asked or named none, for this reason: the daemon's pick takes it.
    Skipped(String),
}

/// The Freestyle step of auto placement. The daemon's verdict (`placement::place`) weighs only
/// the machines it knows, and never claims or wakes a Freestyle slot. When the registry's
/// `lane_place.placement_preference` puts freestyle first and its pick is not a Freestyle host
/// read with room, the registry-declared claim (`lane_overflow.providers` entry
/// `freestyle-lanes`) is asked first, as lane-place asks it (Leo, 2026-11-21: "the sooner you
/// guys move to freestyle the better"). `claim` runs it (`run_claim`; tests answer in process).
pub async fn freestyle_turn<F, Fut>(
    v: &Value,
    registry: Option<&Value>,
    work: &str,
    claim: F,
) -> Freestyle
where
    F: FnOnce(ClaimAsk) -> Fut,
    Fut: std::future::Future<Output = ClaimAnswer>,
{
    use crate::placement::{freestyle_first, is_freestyle};
    if !freestyle_first(registry) {
        return Freestyle::Untouched;
    }
    let pick = v.get("pick").and_then(Value::as_str);
    let room = v.get("room").and_then(Value::as_f64).is_some_and(|r| r >= 1.0);
    let overloaded = v.get("overloaded").and_then(Value::as_bool) == Some(true);
    if pick.is_some_and(|p| is_freestyle(registry, p)) && room && !overloaded {
        return Freestyle::Untouched;
    }
    if work != "agent" {
        return Freestyle::Skipped("a build lane (Freestyle slots take agent lanes only)".into());
    }
    let ask = match claim_ask(
        v,
        registry,
        &leo_workspace(),
        crate::hub::host_label(),
        crate::placement::registry_path().as_deref(),
    ) {
        Ok(ask) => ask,
        Err(why) => return Freestyle::Skipped(why),
    };
    match claim(ask).await {
        Ok(host) => Freestyle::Claimed(host),
        Err(why) => Freestyle::Skipped(why),
    }
}

/// The leo-workspace checkout a provider's argv is relative to.
fn leo_workspace() -> PathBuf {
    dirs::home_dir().unwrap_or_default().join("Projects/leo-workspace")
}

/// The claim's argv and bound, as lane-place's `run_overflow` builds them: the provider's argv
/// under `workspace`, `--origin` this host, `--busy` the hosts the verdict read with no room
/// (the claim skips them), `--budget` its bound less `CLAIM_SLACK_SECS`, `--registry` the
/// registry read. `Err`: why it cannot be asked (the skip line's WHY).
fn claim_ask(
    v: &Value,
    registry: Option<&Value>,
    workspace: &Path,
    origin: &str,
    registry_path: Option<&Path>,
) -> std::result::Result<ClaimAsk, String> {
    let overflow = registry.and_then(|r| r.get("lane_overflow"));
    let provider = overflow
        .and_then(|o| o.get("providers"))
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .find(|p| p.get("name").and_then(Value::as_str) == Some(FREESTYLE_PROVIDER))
        .ok_or("lane_overflow declares no Freestyle provider")?;
    let words: Option<Vec<&str>> = provider
        .get("argv")
        .and_then(Value::as_array)
        .and_then(|a| a.iter().map(Value::as_str).collect());
    let Some([first, rest @ ..]) = words.as_deref() else {
        return Err(format!("{FREESTYLE_PROVIDER}: lane_overflow declares no argv for it"));
    };
    let timeout = overflow
        .and_then(|o| o.get("timeout_seconds"))
        .and_then(Value::as_f64)
        .filter(|s| s.is_finite() && *s >= 1.0)
        .map_or(CLAIM_TIMEOUT_CAP, |s| Duration::from_secs_f64(s).min(CLAIM_TIMEOUT_CAP));
    let mut argv = vec![workspace.join(first).to_string_lossy().into_owned()];
    argv.extend(rest.iter().map(|w| (*w).to_owned()));
    argv.extend(["--origin".to_owned(), origin.to_owned()]);
    let busy: Vec<&str> = v
        .get("hosts")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|h| h.get("load").and_then(Value::as_bool) == Some(true))
        .filter_map(|h| h.get("name").and_then(Value::as_str))
        .collect();
    if !busy.is_empty() {
        argv.extend(["--busy".to_owned(), busy.join(",")]);
    }
    let budget = timeout.as_secs().saturating_sub(CLAIM_SLACK_SECS).max(1);
    argv.extend(["--budget".to_owned(), budget.to_string()]);
    if let Some(path) = registry_path {
        argv.extend(["--registry".to_owned(), path.to_string_lossy().into_owned()]);
    }
    Ok(ClaimAsk { argv, timeout })
}

/// Runs the claim with no stdin, killed when its bound passes.
async fn run_claim(ask: ClaimAsk) -> ClaimAnswer {
    let Some((program, args)) = ask.argv.split_first() else {
        return Err(format!("{FREESTYLE_PROVIDER}: no argv"));
    };
    let mut cmd = tokio::process::Command::new(program);
    cmd.args(args).stdin(Stdio::null()).kill_on_drop(true);
    match tokio::time::timeout(ask.timeout, cmd.output()).await {
        Err(_) => {
            Err(format!("{FREESTYLE_PROVIDER}: gave no answer in {} s", ask.timeout.as_secs()))
        }
        Ok(Err(e)) => Err(format!("{FREESTYLE_PROVIDER}: could not run: {e}")),
        Ok(Ok(out)) => claim_answer(out.status.code(), &String::from_utf8_lossy(&out.stdout)),
    }
}

/// The claim's answer from its exit code and stdout: its last line is `{"host": NAME}` (exit 0)
/// or `{"error": WHY}` (non-zero).
fn claim_answer(code: Option<i32>, stdout: &str) -> ClaimAnswer {
    let last = stdout.lines().rev().find(|l| !l.trim().is_empty()).unwrap_or("{}");
    let Ok(out) = serde_json::from_str::<Value>(last.trim()) else {
        return Err(format!("{FREESTYLE_PROVIDER}: answered {:?}, not JSON", truncate(last)));
    };
    let host = out.get("host").and_then(Value::as_str).filter(|h| !h.is_empty());
    match (code, host) {
        (Some(0), Some(host)) => Ok(host.to_owned()),
        _ => match out.get("error").and_then(Value::as_str) {
            Some(e) => Err(format!("{FREESTYLE_PROVIDER}: {e}")),
            None if code == Some(0) => {
                Err("no Freestyle host was read with room and the claim named none".into())
            }
            None => Err(format!(
                "{FREESTYLE_PROVIDER}: exit {}",
                code.map_or_else(|| "by signal".to_owned(), |c| c.to_string())
            )),
        },
    }
}

fn truncate(s: &str) -> String {
    s.chars().take(60).collect()
}

/// The warning when a machine a person works at finds no fleet host to place on.
fn no_fleet_host(v: &Value) -> String {
    let why = v.get("why").and_then(Value::as_str).unwrap_or("no connected fleet host");
    format!(
        "starting on this machine: no fleet host took it ({why}); `acpmux machine add` connects one"
    )
}

/// Why `new --host auto -n NAME` without `--reuse` stops: NAME already runs.
fn running(name: &str, host: Option<&str>) -> String {
    let at = at(host);
    format!("session {name:?} already runs on {at}; add --reuse to use it, or pick another -n")
}

fn at(host: Option<&str>) -> String {
    host.map_or_else(|| "this machine".to_owned(), str::to_owned)
}

/// Every machine in `_acpmux/sessions`' `list` running a session named
/// `name`, once each: `None` for this machine, else the peer (its rows read
/// `peer/name`).
fn running_on(list: &Value, name: &str) -> Vec<Option<String>> {
    let mut hosts: Vec<Option<String>> = Vec::new();
    for s in list.get("sessions").and_then(Value::as_array).into_iter().flatten() {
        let Some(listed) = s.get("name").and_then(Value::as_str) else { continue };
        let peer = s.get("peer").and_then(Value::as_str);
        let bare = peer.and_then(|p| listed.strip_prefix(p)?.strip_prefix('/')).unwrap_or(listed);
        let host = peer.map(str::to_owned);
        if bare == name && !hosts.contains(&host) {
            hosts.push(host);
        }
    }
    hosts
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

    /// On a machine a person works at, a command-line `new` with no `--host` is placed on a
    /// fleet host; `--host local` and a named host are kept; elsewhere nothing changes.
    #[test]
    fn a_new_from_an_interactive_machine_is_placed_unless_a_host_is_named() {
        assert_eq!(new_target(None, true, false), Target::Place("agent"));
        assert_eq!(new_target(None, true, true), Target::HereForFolder);
        for folder in [true, false] {
            assert_eq!(new_target(None, false, folder), Target::Here);
            for interactive in [true, false] {
                let t = |h| new_target(Some(h), interactive, folder);
                assert_eq!(t("local"), Target::Here);
                assert_eq!(t("auto"), Target::Place("agent"));
                assert_eq!(t("auto-build"), Target::Place("build"));
                assert_eq!(t("box"), Target::Host("box".into()));
            }
        }
        let none = json!({"pick": null, "why": "no host has room for this"});
        // An explicit `--host auto` still stops; only a `new` that named no host starts here,
        // and not on a held machine.
        let e = without_pick(&none, false, None, None).unwrap_err().to_string();
        assert_eq!(e, "no host has room for this");
        assert_eq!(without_pick(&none, true, None, None).unwrap(), None);
        let e = without_pick(&none, true, Some("reserved for sam until x (r)".into()), None);
        assert!(
            e.unwrap_err().to_string().ends_with("this machine is reserved for sam until x (r)")
        );
        assert_eq!(
            no_fleet_host(&none),
            "starting on this machine: no fleet host took it (no host has room for this); \
             `acpmux machine add` connects one"
        );
    }

    fn registry(preference: Value, providers: Value) -> Value {
        json!({
            "lane_place": {"placement_preference": preference},
            "lane_overflow": {"timeout_seconds": 900, "providers": providers},
            "machines": {
                "fs-agent-lane-1": {"provider": "freestyle", "agent_vm": true},
                "gcp-lane-1": {"agent_vm": true, "gcp": {}},
                "big": {},
            },
        })
    }

    async fn never(_: ClaimAsk) -> ClaimAnswer {
        panic!("the claim is not asked")
    }

    fn fs_lanes() -> Value {
        json!([
            {"name": "freestyle-lanes", "argv": ["tools/lane_overflow.py", "freestyle-lanes"]},
            {"name": "gcp", "argv": ["tools/lane_overflow.py", "gcp"]},
        ])
    }

    fn verdict(pick: Option<&str>, room: Option<f64>) -> Value {
        json!({"pick": pick, "room": room, "overloaded": false, "why": "x", "hosts": [
            {"name": "fs-agent-lane-1", "load": true},
            {"name": "gcp-lane-1", "load": false},
        ]})
    }

    /// The claim is asked only when freestyle is first and no Freestyle host was read with room;
    /// a host it names takes the lane, and why it named none is the skip line's WHY.
    #[tokio::test]
    async fn auto_placement_asks_the_freestyle_claim_before_falling_back() {
        let reg = registry(json!(["freestyle", "gcp"]), fs_lanes());
        // A Freestyle host with room: the daemon's pick stands, nothing is claimed.
        let v = verdict(Some("fs-agent-lane-1"), Some(3.0));
        assert_eq!(freestyle_turn(&v, Some(&reg), "agent", never).await, Freestyle::Untouched);
        // Freestyle not first, or no registry: as before.
        let gcp_first = registry(json!(["gcp", "freestyle"]), fs_lanes());
        let v = verdict(Some("gcp-lane-1"), Some(3.0));
        assert_eq!(
            freestyle_turn(&v, Some(&gcp_first), "agent", never).await,
            Freestyle::Untouched
        );
        assert_eq!(freestyle_turn(&v, None, "agent", never).await, Freestyle::Untouched);
        // A GCP pick: the claim is asked, and the host it names takes the lane.
        let named = |ask: ClaimAsk| async move {
            assert!(ask.argv[0].ends_with("tools/lane_overflow.py"), "{:?}", ask.argv);
            assert_eq!(ask.argv[1], "freestyle-lanes");
            assert_eq!(ask.timeout, CLAIM_TIMEOUT_CAP, "900 s is capped");
            ClaimAnswer::Ok("fs-agent-lane-2".to_owned())
        };
        let got = freestyle_turn(&v, Some(&reg), "agent", named).await;
        assert_eq!(got, Freestyle::Claimed("fs-agent-lane-2".into()));
        // No pick at all, or a Freestyle pick with no room, asks it too.
        for v in [verdict(None, None), verdict(Some("fs-agent-lane-1"), Some(0.0))] {
            let refused = |_: ClaimAsk| async {
                ClaimAnswer::Err("freestyle-lanes: skipped (no key)".to_owned())
            };
            let got = freestyle_turn(&v, Some(&reg), "agent", refused).await;
            assert_eq!(got, Freestyle::Skipped("freestyle-lanes: skipped (no key)".into()));
        }
        // A build is never claimed for; a registry with no Freestyle provider says so.
        let got = freestyle_turn(&v, Some(&reg), "build", never).await;
        assert_eq!(
            got,
            Freestyle::Skipped("a build lane (Freestyle slots take agent lanes only)".into())
        );
        let none = registry(json!(["freestyle", "gcp"]), json!([{"name": "gcp", "argv": ["x"]}]));
        let got = freestyle_turn(&v, Some(&none), "agent", never).await;
        assert_eq!(got, Freestyle::Skipped("lane_overflow declares no Freestyle provider".into()));
        assert_eq!(
            freestyle_skipped("lane_overflow declares no Freestyle provider", "gcp-lane-1"),
            "acpmux: freestyle skipped: lane_overflow declares no Freestyle provider; placing on gcp-lane-1"
        );
    }

    /// The argv mirrors lane-place's `run_overflow`: the provider under the workspace, then
    /// --origin, --busy (hosts read with no room), --budget (bound less the slack), --registry.
    #[test]
    fn the_claim_is_asked_as_lane_place_asks_it() {
        let mut reg = registry(json!(["freestyle"]), fs_lanes());
        let v = verdict(Some("gcp-lane-1"), Some(2.0));
        let ask =
            claim_ask(&v, Some(&reg), Path::new("/ws"), "lane-vm", Some(Path::new("/r.json")));
        assert_eq!(
            ask.unwrap(),
            ClaimAsk {
                argv: [
                    "/ws/tools/lane_overflow.py",
                    "freestyle-lanes",
                    "--origin",
                    "lane-vm",
                    "--busy",
                    "fs-agent-lane-1",
                    "--budget",
                    "230",
                    "--registry",
                    "/r.json",
                ]
                .map(str::to_owned)
                .to_vec(),
                timeout: CLAIM_TIMEOUT_CAP,
            }
        );
        reg["lane_overflow"]["timeout_seconds"] = json!(60);
        let ask = claim_ask(&verdict(None, None), Some(&reg), Path::new("/ws"), "o", None).unwrap();
        assert_eq!(ask.timeout, Duration::from_secs(60));
        assert_eq!(ask.argv[ask.argv.len() - 2..], ["--budget".to_owned(), "50".to_owned()]);
        reg["lane_overflow"]["providers"] = json!([{"name": "freestyle-lanes"}]);
        let e = claim_ask(&v, Some(&reg), Path::new("/ws"), "o", None).unwrap_err();
        assert_eq!(e, "freestyle-lanes: lane_overflow declares no argv for it");
    }

    #[test]
    fn the_claims_answer_is_its_last_json_line() {
        assert_eq!(
            claim_answer(Some(0), "log\n{\"host\": \"fs-agent-lane-3\"}\n"),
            Ok("fs-agent-lane-3".into())
        );
        assert_eq!(
            claim_answer(Some(3), "{\"error\": \"skipped (no key)\"}"),
            Err("freestyle-lanes: skipped (no key)".into())
        );
        assert_eq!(
            claim_answer(Some(0), "{}"),
            Err("no Freestyle host was read with room and the claim named none".into())
        );
        assert_eq!(
            claim_answer(Some(3), "{\"host\": \"x\"}"),
            Err("freestyle-lanes: exit 3".into())
        );
        assert_eq!(claim_answer(None, ""), Err("freestyle-lanes: exit by signal".into()));
        assert_eq!(
            claim_answer(Some(0), "oops"),
            Err("freestyle-lanes: answered \"oops\", not JSON".into())
        );
    }

    /// With no pick, the skip reason rides the stop or the start-here warning.
    #[test]
    fn a_skip_with_no_pick_is_said_with_the_outcome() {
        let none = json!({"pick": null, "why": "no host has room for this"});
        let e = without_pick(&none, false, None, Some("freestyle-lanes: skipped (x)")).unwrap_err();
        assert_eq!(
            e.to_string(),
            "no host has room for this; freestyle skipped: freestyle-lanes: skipped (x)"
        );
        assert_eq!(without_pick(&none, true, None, Some("why")).unwrap(), None);
    }

    #[test]
    fn a_running_name_is_found_on_each_machine_that_runs_it() {
        let list = json!({"sessions": [
            {"name": "lane"},
            {"name": "b/lane", "peer": "b"},
            {"name": "c/lane", "peer": "c"},
            {"name": "c/lane", "peer": "c"},
            {"name": "b/other", "peer": "b"},
            {"name": "lane-2"},
        ]});
        assert_eq!(running_on(&list, "lane"), [None, Some("b".into()), Some("c".into())]);
        assert_eq!(running_on(&list, "other"), [Some("b".to_owned())]);
        assert!(running_on(&list, "b").is_empty(), "a peer's name is not a session name");
        assert!(running_on(&list, "fresh").is_empty());
    }
}
