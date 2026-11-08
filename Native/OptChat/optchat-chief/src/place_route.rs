//! Pure machine placement for a spawn; acpmux supplies health and logins.

use crate::acpmux::Family;
use serde_json::Value;

/// `login` in a catalog is a command, not an authentication verdict.
/// Unavailable launchers and known expired/signed-out logins cannot route.
pub fn unavailable(catalog: &Value, health: &Value, harness: &str) -> Option<String> {
    // Reserved Claude route names may resolve to a custom profile. Use the
    // same admission as session launch, then read that profile's auth row.
    let admitted = match crate::harness_gate::admit_peer(catalog, harness) {
        Ok(admitted) => admitted,
        Err(why) => return Some(why),
    };
    let profile = &catalog["harnesses"][&admitted.profile];
    if let Some(why) = profile
        .get("unavailable")
        .filter(|v| !v.is_null() && **v != false)
    {
        return Some(why.as_str().unwrap_or("unavailable on this machine").into());
    }
    let auth = health["harnesses"]
        .as_array()
        .and_then(|rows| rows.iter().find(|r| r["id"] == admitted.profile))
        .and_then(|r| r["auth"].as_str());
    matches!(auth, Some("signedOut" | "expired"))
        .then(|| "its login is unavailable on this machine".into())
}

pub fn login_families(catalog: &Value, health: &Value) -> Vec<Family> {
    let mut families = Vec::new();
    for row in health["harnesses"].as_array().into_iter().flatten() {
        if row["auth"] != "signedIn" {
            continue;
        }
        if let Some(id) = row["id"].as_str()
            && unavailable(catalog, health, id).is_none()
            && let Ok(family) = crate::acpmux::harness_family(catalog, id)
            && !families.contains(&family)
        {
            families.push(family);
        }
    }
    families
}

pub fn machine(name: &str, kind: Kind, health: &Value, logins: Vec<Family>) -> Machine {
    Machine {
        name: name.into(),
        kind,
        os: health["os"].as_str().unwrap_or("").into(),
        connected: true,
        pressure_ok: health
            .pointer("/pressure/ok")
            .and_then(Value::as_bool)
            .unwrap_or(kind == Kind::ThisMac),
        live_sessions: health["liveSessions"].as_u64().unwrap_or(0) as usize,
        logins,
    }
}

/// The single vocabulary of tasks that need a Mac, including the old
/// `subagents::needs_mac` vocabulary. Match whole words and phrases.
const MAC_WORDS: &[&str] = &[
    "ios",
    "iphone",
    "iphones",
    "ipad",
    "ipads",
    "swiftui",
    "uikit",
    "appkit",
    "xcode",
    "simulator",
    "simulators",
    "testflight",
    "macos app",
    "macos apps",
    "screenshot",
    "screenshots",
    "screen recording",
    "screen recordings",
    "computer use",
    "computer-use",
    "cua",
    "reload.sh",
    "--launch",
    "tagged app",
    "tagged apps",
    "tagged build",
    "tagged builds",
    "sign in",
    "sign-in",
    "sign-ins",
    "passkey",
    "passkeys",
    "touch id",
    "keychain",
    "keychains",
    "dogfood",
    "click",
    "drive the app",
];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Need {
    MacOnly,
    Any,
}

impl Need {
    pub fn of(task: &str) -> Self {
        let task = task.to_lowercase();
        if MAC_WORDS.iter().any(|word| {
            task.match_indices(word).any(|(at, _)| {
                let before = task[..at].chars().next_back();
                let after = task[at + word.len()..].chars().next();
                before.is_none_or(|c| !c.is_alphanumeric())
                    && after.is_none_or(|c| !c.is_alphanumeric())
            })
        }) {
            Self::MacOnly
        } else {
            Self::Any
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    ThisMac,
    Paired,
    Cloud,
}

#[derive(Clone, Debug)]
pub struct Machine {
    pub name: String,
    pub kind: Kind,
    pub os: String,
    pub connected: bool,
    pub pressure_ok: bool,
    pub live_sessions: usize,
    pub logins: Vec<Family>,
}

impl Machine {
    pub fn is_mac(&self) -> bool {
        matches!(self.os.to_ascii_lowercase().as_str(), "macos" | "darwin")
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Target {
    Here,
    Peer(String),
    CloudVm,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Placement {
    pub target: Target,
    pub reason: String,
}

impl Placement {
    pub fn line(&self) -> String {
        let name = match &self.target {
            Target::Here => "this Mac",
            Target::Peer(name) => name,
            Target::CloudVm => "cloud",
        };
        format!("on {name}: {}", self.reason)
    }
}

pub fn pick(
    task: &str,
    machines: &[Machine],
    family: Family,
    place: Option<&str>,
) -> Result<Placement, String> {
    let need = Need::of(task);
    let cloud = machines
        .iter()
        .any(|m| m.kind == Kind::Cloud && m.connected);
    if let Some(place) = place {
        let target = match place {
            "here" | "local" | "mac" => Target::Here,
            "cloud" if cloud => Target::CloudVm,
            "cloud" => return Err(
                "no cloud peer is set up: `control cloud PEER[,PEER...]` or set up Cloud machines"
                    .into(),
            ),
            name if machines
                .iter()
                .any(|m| m.kind == Kind::Paired && m.name == name) =>
            {
                Target::Peer(name.into())
            }
            other => {
                let names = machines
                    .iter()
                    .filter(|m| m.kind == Kind::Paired)
                    .map(|m| m.name.as_str())
                    .collect::<Vec<_>>();
                return Err(format!(
                    "spawn: no place {other}; one of here, local, mac, cloud{}",
                    if names.is_empty() {
                        String::new()
                    } else {
                        format!(", {}", names.join(", "))
                    }
                ));
            }
        };
        let reason = if need == Need::MacOnly && target == Target::CloudVm {
            "explicit cloud override; warning: this task needs a Mac"
        } else {
            "explicit place override"
        };
        return Ok(Placement {
            target,
            reason: reason.into(),
        });
    }
    if need == Need::MacOnly
        && machines
            .iter()
            .any(|m| m.kind == Kind::ThisMac && m.is_mac() && m.pressure_ok)
    {
        return Ok(Placement {
            target: Target::Here,
            reason: "this work needs a Mac".into(),
        });
    }
    if need == Need::Any && cloud {
        return Ok(Placement {
            target: Target::CloudVm,
            reason: "general task, Cloud is available".into(),
        });
    }
    let paired = machines
        .iter()
        .enumerate()
        .filter(|(_, m)| {
            m.kind == Kind::Paired
                && m.connected
                && m.pressure_ok
                && m.logins.contains(&family)
                && (need == Need::Any || m.is_mac())
        })
        .min_by_key(|(index, m)| (m.live_sessions, *index));
    if let Some((_, m)) = paired {
        return Ok(Placement {
            target: Target::Peer(m.name.clone()),
            reason: if need == Need::MacOnly {
                "this work needs a Mac; least-loaded available paired Mac"
            } else {
                "Cloud is unavailable; least-loaded paired machine with this harness signed in"
            }
            .into(),
        });
    }
    Ok(Placement {
        target: Target::Here,
        reason: if need == Need::MacOnly {
            "this work needs a Mac; no available paired Mac, staying here"
        } else {
            "Cloud and paired machines with this harness signed in are unavailable"
        }
        .into(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn sanitized_peer_catalog_admits_claude_by_kind_without_command_details() {
        let catalog = json!({"peer": "mini", "harnesses": {
            "claude": {"kind": "claude-stdio", "family": "claude",
                "hasArgs": true, "hasEnv": false, "hasModelsCommand": false, "hasSessions": false},
            "legacy": {"kind": "acp", "family": "claude",
                "hasArgs": true, "hasEnv": false, "hasModelsCommand": false, "hasSessions": false}
        }});
        let health = json!({"harnesses": [{"id": "claude", "auth": "signedIn"}]});
        assert_eq!(unavailable(&catalog, &health, "claude"), None);
        assert_eq!(login_families(&catalog, &health), vec![Family::Claude]);
        assert!(unavailable(&catalog, &health, "legacy").is_some());
        let expired = json!({"harnesses": [{"id": "claude", "auth": "expired"}]});
        assert!(unavailable(&catalog, &expired, "claude").is_some());
        assert!(login_families(&catalog, &expired).is_empty());
    }

    #[test]
    fn reserved_claude_route_reads_the_resolved_custom_profiles_login() {
        let catalog = json!({"harnesses": {"my-direct-login": {
            "kind": "claude-stdio", "argv": ["/usr/local/bin/claude"], "family": "claude"
        }}});
        let health = json!({"harnesses": [{"id": "my-direct-login", "auth": "signedIn"}]});
        assert_eq!(unavailable(&catalog, &health, "claude"), None);
        assert_eq!(login_families(&catalog, &health), vec![Family::Claude]);
        let health = json!({"harnesses": [{"id": "my-direct-login", "auth": "signedOut"}]});
        assert!(unavailable(&catalog, &health, "claude").is_some());
    }

    #[test]
    fn login_commands_are_not_sign_ins_and_unavailable_profiles_do_not_route() {
        let catalog = json!({"harnesses": {
            "claude": {"kind": "claude-stdio", "family": "claude", "argv": ["claude"], "login": ["claude", "auth", "login"]},
            "codex": {"family": "codex", "argv": ["codex"], "unavailable": "not installed"}
        }});
        assert!(login_families(&catalog, &json!({})).is_empty());
        let health = json!({"harnesses": [
            {"id": "claude", "auth": "signedOut"},
            {"id": "codex", "auth": "signedIn"}
        ]});
        assert!(login_families(&catalog, &health).is_empty());
        assert!(unavailable(&catalog, &health, "claude").is_some());
        assert!(unavailable(&catalog, &health, "codex").is_some());
        assert!(unavailable(&catalog, &health, "missing").is_some());
    }

    fn machine(name: &str, kind: Kind, os: &str, load: usize) -> Machine {
        Machine {
            name: name.into(),
            kind,
            os: os.into(),
            connected: true,
            pressure_ok: true,
            live_sessions: load,
            logins: vec![Family::Claude],
        }
    }

    #[test]
    fn task_words_and_fallbacks() {
        let here = machine("here", Kind::ThisMac, "macos", 5);
        let peer = machine("mini", Kind::Paired, "macos", 1);
        let cloud = machine("cloud", Kind::Cloud, "linux", 0);
        let all = [here.clone(), peer.clone(), cloud];
        assert_eq!(
            pick("build a hello iOS view", &all, Family::Claude, None)
                .unwrap()
                .target,
            Target::Here
        );
        assert_eq!(
            pick("build a hello web page", &all, Family::Claude, None)
                .unwrap()
                .target,
            Target::CloudVm
        );
        assert_eq!(
            pick("build a hello web page", &all[..2], Family::Claude, None)
                .unwrap()
                .target,
            Target::Peer("mini".into())
        );
        assert_eq!(
            pick("hello web", &all[..1], Family::Claude, None)
                .unwrap()
                .target,
            Target::Here
        );
        let linux = machine("here", Kind::ThisMac, "linux", 0);
        assert_eq!(
            pick(
                "build a hello iOS view",
                &[linux, peer.clone()],
                Family::Claude,
                None
            )
            .unwrap()
            .target,
            Target::Peer("mini".into())
        );
        let mut busy = here;
        busy.pressure_ok = false;
        assert_eq!(
            pick("SwiftUI", &[busy, peer], Family::Claude, None)
                .unwrap()
                .target,
            Target::Peer("mini".into())
        );
        for task in MAC_WORDS {
            assert_eq!(Need::of(task), Need::MacOnly, "{task}");
        }
        assert_eq!(Need::of("fix the BIOS in a web service"), Need::Any);
        for task in [
            "use the person's passkeys",
            "launch tagged builds",
            "take screen recordings",
            "run the iPhone simulators",
            "debug macOS apps",
        ] {
            assert_eq!(Need::of(task), Need::MacOnly, "{task}");
        }
    }

    #[test]
    fn overrides_login_health_and_stable_ties() {
        let mut all = vec![
            machine("first", Kind::Paired, "macos", 1),
            machine("second", Kind::Paired, "macos", 1),
            machine("cloud", Kind::Cloud, "linux", 0),
        ];
        for place in ["here", "local", "mac"] {
            assert_eq!(
                pick("iOS", &all, Family::Claude, Some(place))
                    .unwrap()
                    .target,
                Target::Here
            );
        }
        assert!(
            pick("iOS", &all, Family::Claude, Some("cloud"))
                .unwrap()
                .reason
                .contains("warning")
        );
        assert_eq!(
            pick("iOS", &all, Family::Claude, Some("second"))
                .unwrap()
                .target,
            Target::Peer("second".into())
        );
        let err = pick("x", &all, Family::Claude, Some("moon")).unwrap_err();
        for name in ["here", "local", "mac", "cloud", "first", "second"] {
            assert!(err.contains(name), "{err}");
        }
        all.pop();
        assert_eq!(
            pick("web", &all, Family::Claude, None).unwrap().target,
            Target::Peer("first".into())
        );
        all[0].connected = false;
        assert_eq!(
            pick("web", &all, Family::Claude, None).unwrap().target,
            Target::Peer("second".into())
        );
        all[1].logins.clear();
        assert_eq!(
            pick("web", &all, Family::Claude, None).unwrap().target,
            Target::Here
        );
    }
}
