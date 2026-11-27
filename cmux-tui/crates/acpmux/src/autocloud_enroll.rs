//! A Remote machine enrolled in AutoCloud: its owner's opt-in ("let AutoCloud use this
//! machine"), the policy of whose work may run there and when, and the `autoCloud` block it
//! reports in its own `_acpmux/host_health` for the placer ([`crate::place_mode`]) to weigh
//! (Leo, 2026-11-25: "i mean remote as in like... would it make sense to enroll remote machines
//! aka stuff like [one of our Macs] capable into the autocloud, or just keep remote as it normally would
//! be"; "and then we eventually serve it to customers. but we're acting as a customer right now
//! is the point").
//!
//! Plain Remote is unchanged: a machine that is not enrolled reports `enrolled: false` and Auto
//! never places on it, as before. Enrollment is the machine's own setting, read on the machine
//! itself, so the owner turns it off where they sit; nothing on another machine can turn it on.
//!
//! The owner always wins: a machine accepts AutoCloud work only while its owner has been away
//! for the policy's idle time (HID idle, [`cmux_host_budget::owner_idle_seconds`]) and inside
//! its hours. An idle time it cannot read is not idle (fail closed), so a Linux box with no
//! HID reading takes placements only when its policy sets `idleSecs: 0` (a headless machine
//! with no owner at its keyboard).
//!
//! Settings (`cmux-next.json`), off unless set:
//! `"cloud": {"autoCloudEnroll": true}` or
//! `"cloud": {"autoCloudEnroll": {"enabled": true, "teams": ["team_id"], "agents": ["claude"],
//! "hours": {"from": 20, "to": 8}, "idleSecs": 600}}`.

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

/// The settings key a machine's owner enrolls it with.
pub const ENROLL_KEY: &str = "cloud.autoCloudEnroll";
/// The `autoCloud` block's version; a reader that sees a higher one still reads the fields it
/// knows (every field is optional with a closed default).
pub const REPORT_VERSION: u32 = 1;
/// How long the owner must have been away before work is placed here: host-presence's bar.
pub const DEFAULT_IDLE_SECS: u64 = 600;

/// Capabilities only a Mac has: work that needs one of them goes to this Mac or an enrolled
/// Mac, never to the cloud (enrolled Macs are AutoCloud's Mac tier).
pub const MAC_CAPS: [&str; 3] = ["macos", "xcode", "ios-simulator"];

/// Local hours `[from, to)` work may be placed, wrapping midnight (`from: 20, to: 8` is
/// overnight). `from == to` is all day.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Hours {
    pub from: u8,
    pub to: u8,
}

impl Hours {
    pub fn contains(self, hour: u8) -> bool {
        let (from, to, h) = (self.from % 24, self.to % 24, hour % 24);
        match from.cmp(&to) {
            std::cmp::Ordering::Equal => true,
            std::cmp::Ordering::Less => (from..to).contains(&h),
            std::cmp::Ordering::Greater => h >= from || h < to,
        }
    }
}

/// Whose work may run here, and when.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Policy {
    /// Teams whose work may run here, besides the owner's own. Empty: the owner's own only.
    pub teams: Vec<String>,
    /// Agents (harness names) that may run here. Empty: any.
    pub agents: Vec<String>,
    /// When. None: any hour.
    pub hours: Option<Hours>,
}

impl Policy {
    /// Whether work for `team` (None: the owner's own) by `agent` may run here.
    pub fn allows(&self, team: Option<&str>, agent: Option<&str>) -> bool {
        let team_ok = match team {
            None => true,
            Some(t) => self.teams.iter().any(|x| x == t),
        };
        let agent_ok = self.agents.is_empty()
            || agent.is_some_and(|a| self.agents.iter().any(|x| x.eq_ignore_ascii_case(a)));
        team_ok && agent_ok
    }
}

/// The owner's enrollment of this machine, as its settings say.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Enrollment {
    pub enabled: bool,
    pub policy: Policy,
    pub idle_secs: u64,
}

impl Default for Enrollment {
    fn default() -> Self {
        Self { enabled: false, policy: Policy::default(), idle_secs: DEFAULT_IDLE_SECS }
    }
}

impl Enrollment {
    /// From a parsed settings document: `true`, or an object with `enabled: true`. Anything
    /// else (missing, `false`, a string, a malformed object) is not enrolled.
    pub fn from_doc(doc: &Value) -> Self {
        crate::user_settings::value(doc, ENROLL_KEY)
            .map(|v| Self::from_value(&v))
            .unwrap_or_default()
    }

    /// From the setting's own value: `true`, or an object with `enabled: true`. Anything else
    /// is not enrolled.
    pub fn from_value(v: &Value) -> Self {
        match v {
            Value::Bool(true) => Self { enabled: true, ..Self::default() },
            // An object's policy is kept when it is off, so turning it back on keeps its rules.
            Value::Object(_) => {
                let policy = serde_json::from_value::<Policy>(v.clone());
                let Ok(policy) = policy else { return Self::default() };
                let idle_secs =
                    v.get("idleSecs").and_then(Value::as_u64).unwrap_or(DEFAULT_IDLE_SECS);
                let enabled = v.get("enabled") == Some(&Value::Bool(true));
                Self { enabled, policy, idle_secs }
            }
            _ => Self::default(),
        }
    }

    /// The setting's value for this enrollment (what `_acpmux/autocloud_enroll` saves).
    pub fn to_value(&self) -> Value {
        // `IndexMut` on a `Value` panics on a non-object; a policy that does not serialize to
        // an object starts from an empty one instead.
        let mut map = match serde_json::to_value(&self.policy) {
            Ok(Value::Object(map)) => map,
            _ => serde_json::Map::new(),
        };
        map.insert("enabled".into(), json!(self.enabled));
        map.insert("idleSecs".into(), json!(self.idle_secs));
        Value::Object(map)
    }

    /// This enrollment with the fields `params` names replaced: `enabled`, `teams`, `agents`,
    /// `hours` (null clears it), `idleSecs`. A field of the wrong type is an error.
    pub fn with(&self, params: &Value) -> Result<Self, String> {
        let mut next = self.clone();
        if let Some(v) = params.get("enabled") {
            next.enabled = v.as_bool().ok_or("enabled must be true or false")?;
        }
        for (key, slot) in [("teams", &mut next.policy.teams), ("agents", &mut next.policy.agents)]
        {
            if let Some(v) = params.get(key) {
                *slot = serde_json::from_value(v.clone())
                    .map_err(|_| format!("{key} must be a list of strings"))?;
            }
        }
        if let Some(v) = params.get("hours") {
            next.policy.hours = serde_json::from_value(v.clone())
                .map_err(|_| "hours must be {from, to} or null".to_owned())?;
        }
        if let Some(v) = params.get("idleSecs") {
            next.idle_secs = v.as_u64().ok_or("idleSecs must be a whole number of seconds")?;
        }
        Ok(next)
    }

    /// This machine's enrollment, read from its settings file now. A missing or unreadable file
    /// is not enrolled.
    pub fn read() -> Self {
        use crate::user_settings::{self, Settings};
        match user_settings::read() {
            Settings::Parsed(doc) => Self::from_doc(&doc),
            _ => Self::default(),
        }
    }

    /// The enrollment in force: what `_acpmux/autocloud_enroll` saved in the daemon config
    /// (`saved`), else the settings key.
    pub fn resolve(saved: Option<&Value>) -> Self {
        saved.map(Self::from_value).unwrap_or_else(Self::read)
    }
}

/// The `autoCloud` block of a machine's `_acpmux/host_health`.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Report {
    pub v: u32,
    pub enrolled: bool,
    /// Enrolled, the owner away long enough and inside the policy's hours: it takes new work.
    pub accepting: bool,
    /// Whether the owner has been away for the policy's idle time. None: unread (not idle).
    pub owner_idle: Option<bool>,
    pub owner_idle_secs: Option<u64>,
    pub in_hours: bool,
    pub policy: Policy,
    /// What work this machine can run: `macos`, `xcode`, `ios-simulator`, `linux`, `arm64`,
    /// `x86_64`, `gpu-metal`, `gpu-nvidia`.
    pub caps: Vec<String>,
    /// Why it does not accept work now, in a few words; empty when it does.
    pub why: String,
}

impl Report {
    /// Whether this machine has every capability in `need`.
    pub fn fits(&self, need: &[String]) -> bool {
        need.iter().all(|n| self.caps.iter().any(|c| c.eq_ignore_ascii_case(n)))
    }

    /// The block from a health reading (`health.autoCloud`); a machine on an older build has
    /// none, and is not enrolled.
    pub fn of_health(health: &Value) -> Self {
        health
            .get("autoCloud")
            .and_then(|v| serde_json::from_value(v.clone()).ok())
            .unwrap_or_default()
    }
}

/// The report for `enrollment` with the owner away `idle` seconds (None: unread), at local
/// `hour`, on a machine with `caps`.
pub fn report(enrollment: &Enrollment, idle: Option<f64>, hour: u8, caps: Vec<String>) -> Report {
    let idle_secs = idle.map(|s| s.max(0.0) as u64);
    let owner_idle = if enrollment.idle_secs == 0 {
        Some(true)
    } else {
        idle_secs.map(|s| s >= enrollment.idle_secs)
    };
    let in_hours = enrollment.policy.hours.is_none_or(|h| h.contains(hour));
    let why = if !enrollment.enabled {
        "not enrolled".to_owned()
    } else if owner_idle.is_none() {
        "owner presence unread".to_owned()
    } else if owner_idle == Some(false) {
        format!("owner active (away {}s of {}s)", idle_secs.unwrap_or(0), enrollment.idle_secs)
    } else if !in_hours {
        "outside its hours".to_owned()
    } else {
        String::new()
    };
    Report {
        v: REPORT_VERSION,
        enrolled: enrollment.enabled,
        accepting: why.is_empty(),
        owner_idle,
        owner_idle_secs: idle_secs,
        in_hours,
        policy: enrollment.policy.clone(),
        caps,
        why,
    }
}

/// This machine's report now: its enrollment (`Enrollment::resolve`), its owner's HID idle, its local hour, its caps.
pub fn report_now(saved: Option<&Value>) -> Report {
    use chrono::Timelike;
    let enrollment = Enrollment::resolve(saved);
    let hour = chrono::Local::now().hour() as u8;
    report(&enrollment, cmux_host_budget::owner_idle_seconds(), hour, caps_now())
}

/// What this machine can run, read from its OS, architecture and installed tools.
pub fn caps_now() -> Vec<String> {
    let mut caps = vec![std::env::consts::ARCH.replace("aarch64", "arm64")];
    let exists = |p: &str| std::path::Path::new(p).exists();
    if cfg!(target_os = "macos") {
        caps.push("macos".into());
        if std::env::consts::ARCH == "aarch64" {
            caps.push("gpu-metal".into());
        }
        if exists("/Applications/Xcode.app") {
            caps.push("xcode".into());
            if exists("/Library/Developer/CoreSimulator") {
                caps.push("ios-simulator".into());
            }
        }
    } else if cfg!(target_os = "linux") {
        caps.push("linux".into());
        if exists("/dev/nvidia0") {
            caps.push("gpu-nvidia".into());
        }
    }
    caps
}

#[cfg(test)]
#[path = "autocloud_enroll/tests.rs"]
mod tests;
