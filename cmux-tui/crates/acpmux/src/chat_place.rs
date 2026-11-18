//! Auto chat placement: where a new chat starts (This Mac, a joined machine or Cloud), and when
//! Auto moves a running chat and brings it back (design/auto-chat-placement.md).
//!
//! Leo, 2026-11-18: "an auto mode as an umbrella over remote/local/cloud itself. so it just goes.
//! thats essentialyl what we're doing rn with teh lanes going to various machines".
//!
//! The machines are weighed by `placement.rs`, the Rust port of lane-place's scoring (room in
//! lanes from RAM, CPU, disk and live agents, `placement_preference` tiers, rank, holds), so a
//! chat lands the way our lanes do. On top of that, a chat brings what a lane does not: the
//! folder it works in and its size, this Mac's battery and lid, the network, what the work needs
//! (macOS, a GPU, a long build) and whether Cloud is available on the person's plan.
//!
//! Pure: [`decide`] and [`rejudge`] read only their input, so every case is a unit test. The
//! request `_acpmux/place_chat` (`server/chat_place.rs`) fills the input from this machine's
//! health and each joined machine's last reading.

use crate::placement::{self, Candidate, Work};
use serde::Deserialize;
use serde_json::{Value, json};

const GB: f64 = 1024.0 * 1024.0 * 1024.0;

/// On battery under this percent, this Mac counts as over load: a chat should not drain it.
pub const LOW_BATTERY_PERCENT: f64 = 20.0;
/// A chat Auto moved off this Mac for its battery comes back at or over this percent (or on AC).
pub const BACK_BATTERY_PERCENT: f64 = 30.0;
/// A folder bigger than this prefers a machine that already has a copy of it.
pub const COPY_BUDGET_BYTES: u64 = 2 * 1024 * 1024 * 1024;
/// How long this Mac must stay over load or low on battery before Auto moves a running chat:
/// a burst of load (a build finishing) moves nothing.
pub const HOLD_SECS: u64 = 120;
/// The room in lanes this Mac needs before a moved chat comes back: one lane for the chat, one
/// spare, so it does not leave again at once.
pub const BACK_ROOM_LANES: f64 = 2.0;

/// What the work needs.
#[derive(Clone, Debug, Default, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct Needs {
    /// Apple-only work (Xcode, a macOS app): only a Mac runs it; Cloud is Linux.
    pub macos: bool,
    /// A GPU: only machines whose health says `gpu`, and Cloud when the plan offers one.
    pub gpu: bool,
    /// A long build or test run: it takes the room of two lanes, and goes to build hosts.
    pub long_build: bool,
}

/// The folder the chat works in.
#[derive(Clone, Debug, Default, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct Folder {
    /// Its size, from a bounded walk (`None`: not measured, or past the walk's bound).
    pub bytes: Option<u64>,
    /// Joined machines that already hold a copy (a clone, an earlier seed).
    pub peers_with_copy: Vec<String>,
}

/// Cloud on the person's plan, as the app knows it.
#[derive(Clone, Debug, Default, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct Cloud {
    /// Signed in, with a plan that starts Cloud machines.
    pub available: bool,
    /// The plan offers a GPU machine.
    pub gpu: bool,
    /// What an hour costs on the plan, in the plan's own units (shown, and weighed only against
    /// running overloaded on this Mac; a joined machine with room always beats it).
    pub hourly_cost: Option<f64>,
    /// What is left of the plan's allowance in the same units; at or under 0, Cloud is out.
    pub budget_left: Option<f64>,
}

/// This Mac's power and network, from its health (`power`, `network`) or the app's sleep event.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Power {
    pub battery_percent: Option<f64>,
    pub on_ac: Option<bool>,
    pub lid_closed: bool,
    /// The system said it will sleep (the app's `willSleep`), until it wakes.
    pub sleeping: bool,
    /// `false` only when the health says the network is down.
    pub network_up: bool,
}

impl Power {
    /// From a health reading's `power` and `network` objects; missing fields read as the safe
    /// default (lid open, awake, network up, battery unknown).
    pub fn from_health(h: &Value) -> Self {
        let p = h.get("power");
        let flag = |k: &str| p.and_then(|p| p.get(k)).and_then(Value::as_bool);
        Self {
            battery_percent: p
                .and_then(|p| p.get("batteryPercent"))
                .and_then(Value::as_f64)
                .filter(|n| n.is_finite()),
            on_ac: flag("onAc"),
            lid_closed: flag("lidClosed") == Some(true),
            sleeping: flag("sleeping") == Some(true),
            network_up: h.pointer("/network/up").and_then(Value::as_bool) != Some(false),
        }
    }

    /// This Mac cannot run a chat now: its lid is closed or it is going to sleep.
    pub fn away(&self) -> bool {
        self.lid_closed || self.sleeping
    }

    /// On battery and under [`LOW_BATTERY_PERCENT`].
    pub fn low_battery(&self) -> bool {
        self.on_ac != Some(true) && self.battery_percent.is_some_and(|b| b < LOW_BATTERY_PERCENT)
    }

    /// Battery is no reason to stay away: on AC, unknown, or at [`BACK_BATTERY_PERCENT`].
    pub fn battery_ok_to_return(&self) -> bool {
        self.on_ac == Some(true) || self.battery_percent.is_none_or(|b| b >= BACK_BATTERY_PERCENT)
    }
}

/// Everything [`decide`] weighs.
#[derive(Clone, Debug)]
pub struct Input {
    /// This machine, with its health read now.
    pub local: Candidate,
    /// Joined machines, with their last readings.
    pub peers: Vec<Candidate>,
    /// fleet-registry.json, when this machine is in the fleet.
    pub registry: Option<Value>,
    pub power: Power,
    pub folder: Folder,
    pub needs: Needs,
    pub cloud: Cloud,
}

/// A place.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Place {
    Local,
    Peer(String),
    Cloud,
}

impl Place {
    pub fn kind(&self) -> &'static str {
        match self {
            Self::Local => "local",
            Self::Peer(_) => "peer",
            Self::Cloud => "cloud",
        }
    }

    pub fn peer(&self) -> Option<&str> {
        match self {
            Self::Peer(p) => Some(p),
            _ => None,
        }
    }

    /// From `{place, peer}` as the verdict and the app write it.
    pub fn parse(kind: &str, peer: Option<&str>) -> Option<Self> {
        match (kind, peer) {
            ("local", _) => Some(Self::Local),
            ("cloud", _) => Some(Self::Cloud),
            ("peer", Some(p)) if !p.is_empty() => Some(Self::Peer(p.to_owned())),
            _ => None,
        }
    }
}

/// Where a chat goes and why.
#[derive(Clone, Debug, PartialEq)]
pub struct Verdict {
    pub place: Place,
    /// One line for the chip: "This Mac: room for 6", "huge-blue: This Mac is busy (...)".
    pub why: String,
    /// Every rule that weighed in, in order.
    pub reasons: Vec<String>,
    /// No place had room and this Mac takes it anyway (load only warns, as for lanes).
    pub overloaded: bool,
    /// This Mac's own weighing (`placement::place`'s host row).
    pub local: Value,
    /// The joined machines' weighing (`placement::place`'s verdict).
    pub peers: Value,
}

impl Verdict {
    /// The `_acpmux/place_chat` result.
    pub fn to_json(&self) -> Value {
        json!({
            "place": self.place.kind(),
            "peer": self.place.peer(),
            "why": self.why,
            "reasons": self.reasons,
            "overloaded": self.overloaded,
            "local": self.local,
            "peers": self.peers,
        })
    }
}

fn work(needs: &Needs) -> Work {
    if needs.long_build { Work::Build } else { Work::Agent }
}

fn is_mac(c: &Candidate) -> bool {
    matches!(c.health.get("os").and_then(Value::as_str), Some("macos"))
}

fn has_gpu(c: &Candidate) -> bool {
    match c.health.get("gpu") {
        Some(Value::Bool(b)) => *b,
        Some(Value::Null) | None => false,
        Some(_) => true,
    }
}

/// This Mac weighed alone, with the registry only when it has a `lanes` entry for this machine
/// (a person's Mac usually has none, and is weighed with placement's defaults, never refused as
/// "not a lane host").
fn weigh_local(input: &Input) -> Value {
    let reg = input.registry.as_ref().filter(|r| {
        placement::lane_hosts(Some(r))
            .is_some_and(|hosts| placement::registry_lanes(&hosts, &input.local.name).is_some())
    });
    let v = placement::place(std::slice::from_ref(&input.local), reg, work(&input.needs));
    v.get("hosts").and_then(|h| h.get(0)).cloned().unwrap_or(Value::Null)
}

/// This Mac has room for the work: it takes it, is not over its budget, and has room for one lane
/// (two for a long build). A reading with no numbers counts as room: a Mac whose health is unknown
/// keeps its chats, as before Auto.
fn local_room(row: &Value, needs: &Needs) -> Result<f64, String> {
    if row["ok"] != true {
        return Err(row["refused"].as_str().unwrap_or("not available").to_owned());
    }
    let need = if needs.long_build { 2.0 } else { 1.0 };
    match row["room"].as_f64() {
        Some(r) if r < need => Err(format!("room for {r:.0}, the work needs {need:.0}")),
        Some(r) => Ok(r),
        None => Ok(f64::INFINITY),
    }
}

/// Joined machines that can run the work: macOS work only on Macs, GPU work only with a GPU.
fn eligible_peers(input: &Input) -> Vec<Candidate> {
    input
        .peers
        .iter()
        .filter(|c| !input.needs.macos || is_mac(c))
        .filter(|c| !input.needs.gpu || has_gpu(c))
        .cloned()
        .collect()
}

/// The best joined machine with room, by placement's order; a folder past the copy budget prefers
/// one that already holds it.
fn pick_peer(input: &Input, peers: &Value) -> Option<String> {
    let rows = peers["hosts"].as_array()?;
    let ok = |name: &str| {
        rows.iter().any(|h| h["name"] == name && h["ok"] == true && h["room"].as_f64() != Some(0.0))
    };
    let big = input.folder.bytes.is_some_and(|b| b > COPY_BUDGET_BYTES);
    if big && let Some(p) = input.folder.peers_with_copy.iter().find(|p| ok(p)) {
        return Some(p.clone());
    }
    if peers["overloaded"] == true {
        return None;
    }
    peers["pick"].as_str().map(str::to_owned)
}

fn cloud_usable(input: &Input) -> Result<(), &'static str> {
    if !input.cloud.available {
        return Err("Cloud is not on this account");
    }
    if input.needs.macos {
        return Err("the work needs macOS and Cloud is Linux");
    }
    if input.needs.gpu && !input.cloud.gpu {
        return Err("the work needs a GPU and the plan has none");
    }
    if input.cloud.budget_left.is_some_and(|b| b <= 0.0) {
        return Err("the plan's Cloud allowance is used up");
    }
    Ok(())
}

fn size_text(bytes: Option<u64>) -> String {
    match bytes {
        Some(b) if b as f64 >= GB => format!("{:.1} GB", b as f64 / GB),
        Some(b) => format!("{:.0} MB", b as f64 / (1024.0 * 1024.0)),
        None => "size unknown".into(),
    }
}

/// Where a new chat on Auto starts.
pub fn decide(input: &Input) -> Verdict {
    decide_with(input, false)
}

/// [`decide`]; with `leave_local`, this Mac is not a candidate except as the last resort (Auto is
/// moving a chat off it).
fn decide_with(input: &Input, leave_local: bool) -> Verdict {
    let mut reasons = Vec::new();
    let local = weigh_local(input);
    let peers_in = eligible_peers(input);
    let peers = placement::place(&peers_in, input.registry.as_ref(), work(&input.needs));
    let verdict = |place: Place, why: String, reasons: Vec<String>, overloaded: bool| Verdict {
        place,
        why,
        reasons,
        overloaded,
        local: local.clone(),
        peers: peers.clone(),
    };
    reasons.push(format!("folder {}", size_text(input.folder.bytes)));

    // 1. Needs that only this Mac meets.
    if input.needs.macos && !is_mac(&input.local) && peers_in.is_empty() {
        reasons.push("the work needs macOS and no joined machine is a Mac".into());
    }
    // 2. With the network down nothing else can be reached.
    if !input.power.network_up {
        reasons.push("the network is down".into());
        return verdict(Place::Local, "This Mac: the network is down".into(), reasons, false);
    }
    // 3-5. This Mac, unless it is away, low on battery or out of room.
    let local_ok = if input.power.away() {
        Err(if input.power.lid_closed { "the lid is closed" } else { "it is going to sleep" }
            .to_owned())
    } else if input.power.low_battery() {
        Err(format!("on battery at {:.0}%", input.power.battery_percent.unwrap_or_default()))
    } else if input.needs.macos && !is_mac(&input.local) {
        Err("the work needs macOS".to_owned())
    } else if input.needs.gpu && !has_gpu(&input.local) {
        Err("the work needs a GPU".to_owned())
    } else if leave_local {
        Err("Auto is moving the chat off it".to_owned())
    } else {
        local_room(&local, &input.needs)
    };
    match &local_ok {
        Ok(room) => {
            let room = if room.is_finite() { format!("room for {room:.0}") } else { "room".into() };
            reasons.push(format!("This Mac has {room}"));
            return verdict(Place::Local, format!("This Mac: {room}"), reasons, false);
        }
        Err(why) => reasons.push(format!("This Mac: {why}")),
    }
    let busy = local_ok.err().unwrap_or_default();
    // 6. The best joined machine with room.
    if let Some(peer) = pick_peer(input, &peers) {
        let row = peers
            .get("hosts")
            .and_then(Value::as_array)
            .and_then(|r| r.iter().find(|h| h["name"] == peer.as_str()))
            .and_then(|h| h["why"].as_str())
            .unwrap_or_default()
            .to_owned();
        reasons.push(format!("{peer}: {row}"));
        return verdict(
            Place::Peer(peer.clone()),
            format!("{peer}: This Mac {}", busy_phrase(&busy)),
            reasons,
            false,
        );
    }
    if !peers_in.is_empty() {
        reasons.push("no joined machine has room".into());
    }
    // 7. Cloud.
    match cloud_usable(input) {
        Ok(()) => {
            let cost = input
                .cloud
                .hourly_cost
                .map(|c| format!(" ({c} an hour on the plan)"))
                .unwrap_or_default();
            reasons.push(format!("Cloud{cost}"));
            return verdict(
                Place::Cloud,
                format!("Cloud: This Mac {}", busy_phrase(&busy)),
                reasons,
                false,
            );
        }
        Err(why) => reasons.push(why.into()),
    }
    // 8. This Mac anyway: load only warns.
    reasons.push("no other place takes it, so This Mac does".into());
    verdict(Place::Local, format!("This Mac: {busy}, and no other place takes it"), reasons, true)
}

fn busy_phrase(why: &str) -> String {
    if why.starts_with("the lid") || why.starts_with("it is going") || why.starts_with("on battery")
    {
        format!("is away ({why})")
    } else if why.starts_with("the work needs") {
        format!("cannot run it ({why})")
    } else {
        format!("is busy ({why})")
    }
}

/// A running chat as Auto sees it.
#[derive(Clone, Debug, PartialEq)]
pub struct Running {
    /// Where it runs now.
    pub place: Place,
    /// Where it started: Auto brings it back there.
    pub home: Place,
    /// The person pinned it, or moved it themselves: Auto leaves it alone.
    pub pinned: bool,
    /// Its turn is still running: it comes back only between turns.
    pub turn_active: bool,
    /// How long this Mac has been over load or low on battery (0: it is not).
    pub local_over_secs: u64,
}

/// A move Auto makes.
#[derive(Clone, Debug, PartialEq)]
pub struct Move {
    pub to: Place,
    pub why: String,
    /// It brings the chat back to where it started.
    pub back: bool,
}

impl Move {
    pub fn to_json(&self) -> Value {
        json!({"to": self.to.kind(), "peer": self.to.peer(), "why": self.why, "back": self.back})
    }
}

/// Whether Auto moves a running chat now: off this Mac at once when its lid closes or it goes to
/// sleep, and after [`HOLD_SECS`] of load or low battery; back home when that has cleared, this
/// Mac has room for [`BACK_ROOM_LANES`], and the chat's turn has ended. A pinned chat never moves,
/// and with the network down nothing moves.
pub fn rejudge(running: &Running, input: &Input) -> Option<Move> {
    if running.pinned || !input.power.network_up {
        return None;
    }
    if running.place == Place::Local {
        let hard = input.power.away();
        if !hard {
            let row = weigh_local(input);
            let over = input.power.low_battery() || local_room(&row, &input.needs).is_err();
            if !over || running.local_over_secs < HOLD_SECS {
                return None;
            }
        }
        let v = decide_with(input, true);
        if v.place == Place::Local {
            return None;
        }
        return Some(Move { to: v.place, why: v.why, back: false });
    }
    // Away from home: come back when home is fine again.
    if running.home != Place::Local {
        return None;
    }
    if input.power.away() || !input.power.battery_ok_to_return() || running.turn_active {
        return None;
    }
    let row = weigh_local(input);
    let room = match local_room(&row, &input.needs) {
        Ok(r) => r,
        Err(_) => return None,
    };
    if room < BACK_ROOM_LANES {
        return None;
    }
    let room = if room.is_finite() { format!("room for {room:.0}") } else { "room".into() };
    Some(Move { to: Place::Local, why: format!("This Mac is back: {room}"), back: true })
}

#[cfg(test)]
#[path = "chat_place_tests.rs"]
mod tests;
