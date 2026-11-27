//! The phone's connection contract at the FFI boundary (`tests/fixtures/connection_contract.json`,
//! map in `cmux-next-ios/contract/README.md`).
//!
//! Rust side: every reachability case resolves as the fixture says; every `LinkEvent` and
//! `MediaState` variant is named in the fixture and used by a scenario (the `match`es below are
//! exhaustive, so a new variant is a compile error here first); every scenario's link events
//! follow the order `LinkEvent` documents; every protocol version equals the fixture's and names
//! old-peer tests that exist. Swift reads the same file (CmuxMobileLinkFFILinuxTests,
//! CmuxMobileLiveTests, CmuxMobileModelTests), so a Rust change that lands here fails there
//! until iOS handles it.

use std::collections::BTreeSet;
use std::path::PathBuf;

use cmux_mobile_link_ffi::{
    LinkEvent, LinkPath, MacLinkFailureKind, MacLinkState, MacReachabilityInput,
    MacReachabilityKind, MacRecoveryActionKind, MediaState, Transport, mac_reachability_action,
    mac_reachability_resolve, mac_reachability_span,
};
use serde_json::Value;

fn crates_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).parent().unwrap().to_path_buf()
}

fn fixture() -> Value {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/connection_contract.json");
    serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap()
}

fn names(v: &Value, key: &str) -> Vec<String> {
    v[key].as_array().unwrap().iter().map(|s| s.as_str().unwrap().to_string()).collect()
}

fn link_event_name(e: &LinkEvent) -> &'static str {
    match e {
        LinkEvent::Connecting { .. } => "Connecting",
        LinkEvent::Connected { .. } => "Connected",
        LinkEvent::PathChanged { .. } => "PathChanged",
        LinkEvent::Rtt { .. } => "Rtt",
        LinkEvent::Media { .. } => "Media",
        LinkEvent::Disconnected { .. } => "Disconnected",
        LinkEvent::Suspect { .. } => "Suspect",
    }
}

fn media_name(m: &MediaState) -> &'static str {
    match m {
        MediaState::Off => "Off",
        MediaState::Connecting => "Connecting",
        MediaState::Up { .. } => "Up",
        MediaState::Failed { .. } => "Failed",
    }
}

fn kind_name(k: &MacReachabilityKind) -> &'static str {
    match k {
        MacReachabilityKind::Connected => "Connected",
        MacReachabilityKind::Connecting => "Connecting",
        MacReachabilityKind::NotConnected => "NotConnected",
        MacReachabilityKind::Slow { .. } => "Slow",
        MacReachabilityKind::Offline => "Offline",
        MacReachabilityKind::NoAnswer { .. } => "NoAnswer",
        MacReachabilityKind::ServiceDown => "ServiceDown",
        MacReachabilityKind::AuthRequired => "AuthRequired",
        MacReachabilityKind::NotAllowed => "NotAllowed",
        MacReachabilityKind::PhoneOffline => "PhoneOffline",
    }
}

fn path(v: &Value) -> LinkPath {
    match v.as_str().unwrap_or("Direct") {
        "Direct" => LinkPath::Direct,
        "Turn" => LinkPath::Turn,
        "TurnTls" => LinkPath::TurnTls,
        "HttpsRelay" => LinkPath::HttpsRelay,
        "NoPath" => LinkPath::NoPath,
        other => panic!("unknown path {other}"),
    }
}

fn u32_of(v: &Value) -> u32 {
    v.as_u64().map(|n| u32::try_from(n).unwrap()).unwrap_or(0)
}

/// A `link` step as the real event the binding hands Swift.
fn link_event(step: &Value) -> LinkEvent {
    let transport = Transport::WireGuard;
    match step["event"].as_str().unwrap() {
        "Connecting" => LinkEvent::Connecting { transport },
        "Connected" => LinkEvent::Connected { transport, path: path(&step["path"]) },
        "PathChanged" => LinkEvent::PathChanged { path: path(&step["path"]) },
        "Rtt" => LinkEvent::Rtt { millis: u32_of(&step["millis"]) },
        "Media" => LinkEvent::Media {
            state: match step["media"].as_str().unwrap() {
                "Off" => MediaState::Off,
                "Connecting" => MediaState::Connecting,
                "Up" => MediaState::Up {
                    path: path(&step["path"]),
                    rtt_millis: step["rtt_millis"].as_u64().map(|n| n as u32),
                },
                "Failed" => MediaState::Failed {
                    reason: step["reason"].as_str().unwrap_or("").to_string(),
                    retry_in_millis: u32_of(&step["retry_in_millis"]),
                },
                other => panic!("unknown media {other}"),
            },
        },
        "Disconnected" => {
            LinkEvent::Disconnected { reason: step["reason"].as_str().unwrap_or("").to_string() }
        }
        "Suspect" => LinkEvent::Suspect { silent_millis: u32_of(&step["silent_millis"]) },
        other => panic!("unknown link event {other}"),
    }
}

#[test]
fn every_link_event_and_media_variant_is_in_the_contract_and_a_scenario() {
    let f = fixture();
    let mut events = BTreeSet::new();
    let mut media = BTreeSet::new();
    for s in f["scenarios"].as_array().unwrap() {
        for step in s["steps"].as_array().unwrap() {
            if step["do"] == "link" {
                let e = link_event(step);
                events.insert(link_event_name(&e).to_string());
                if let LinkEvent::Media { state } = &e {
                    media.insert(media_name(state).to_string());
                }
            }
        }
    }
    let want_events: BTreeSet<_> = names(&f, "link_event_variants").into_iter().collect();
    let want_media: BTreeSet<_> = names(&f, "media_state_variants").into_iter().collect();
    assert_eq!(events, want_events, "a LinkEvent variant no scenario sends");
    assert_eq!(media, want_media, "a MediaState variant no scenario sends");
}

#[test]
fn every_scenario_follows_the_documented_link_event_order() {
    // Connecting, then Connected (or Disconnected when the dial fails), then any number of
    // PathChanged, Rtt, Media and Suspect, then one Disconnected. A dial_failed, a drop or a
    // fresh dial ends the link the machine knew; stale steps belong to a dead link.
    #[derive(PartialEq, Debug, Clone, Copy)]
    enum L { None, Dialing, Up }
    let f = fixture();
    for s in f["scenarios"].as_array().unwrap() {
        let name = s["name"].as_str().unwrap();
        let mut l = L::None;
        for (i, step) in s["steps"].as_array().unwrap().iter().enumerate() {
            let at = format!("{name} step {i}");
            if step["stale"] == true {
                assert_ne!(step["event"], "Connected", "{at}: a stale Connected would open a link");
                continue;
            }
            match step["do"].as_str().unwrap() {
                "link" => {
                    let e = link_event(step);
                    l = match (l, &e) {
                        (L::None | L::Dialing, LinkEvent::Connecting { .. }) => L::Dialing,
                        (L::None | L::Dialing, LinkEvent::Connected { .. }) => L::Up,
                        (L::Dialing | L::Up, LinkEvent::Disconnected { .. }) => L::None,
                        (
                            L::Up,
                            LinkEvent::PathChanged { .. }
                            | LinkEvent::Rtt { .. }
                            | LinkEvent::Media { .. }
                            | LinkEvent::Suspect { .. },
                        ) => L::Up,
                        (state, e) => panic!("{at}: {} after {state:?}", link_event_name(e)),
                    };
                }
                "dial_failed" | "probe_failed" => l = L::None,
                // A fresh dial is a new link (the old one, if kept, is the standby).
                _ if step["effects"].as_array().unwrap().iter().any(|e| e == "dial") => l = L::None,
                _ => {}
            }
        }
    }
}

#[test]
fn every_scenario_names_a_known_behaviour_and_every_behaviour_has_one() {
    let f = fixture();
    let want: BTreeSet<_> = names(&f, "behaviours").into_iter().collect();
    let got: BTreeSet<_> = f["scenarios"]
        .as_array()
        .unwrap()
        .iter()
        .map(|s| s["behaviour"].as_str().unwrap().to_string())
        .collect();
    assert_eq!(got, want);
}

#[test]
fn every_reachability_case_resolves_as_the_contract_says() {
    let f = fixture();
    let mut seen = BTreeSet::new();
    for c in f["reachability"].as_array().unwrap() {
        let name = c["name"].as_str().unwrap();
        let i = &c["input"];
        let input = MacReachabilityInput {
            is_online: i["is_online"].as_bool().unwrap(),
            quiet_ms: i["quiet_ms"].as_i64(),
            connection: i["connection"].as_str().map(|s| match s {
                "Connecting" => MacLinkState::Connecting,
                "Connected" => MacLinkState::Connected,
                "Failed" => MacLinkState::Failed,
                other => panic!("{name}: unknown connection {other}"),
            }),
            failure: i["failure"].as_str().map(|s| match s {
                "HostUnreachable" => MacLinkFailureKind::HostUnreachable,
                "ServiceDown" => MacLinkFailureKind::ServiceDown,
                "AuthRequired" => MacLinkFailureKind::AuthRequired,
                "NotAllowed" => MacLinkFailureKind::NotAllowed,
                other => panic!("{name}: unknown failure {other}"),
            }),
            live: i["live"].as_bool().unwrap_or(true),
            phone_offline: i["phone_offline"].as_bool().unwrap_or(false),
        };
        let got = mac_reachability_resolve(input);
        let e = &c["expect"];
        assert_eq!(kind_name(&got), e["kind"].as_str().unwrap(), "{name}");
        match got {
            MacReachabilityKind::Slow { quiet_seconds } => {
                assert_eq!(Some(quiet_seconds), e["quiet_seconds"].as_i64(), "{name}")
            }
            MacReachabilityKind::NoAnswer { listed_online } => {
                assert_eq!(Some(listed_online), e["listed_online"].as_bool(), "{name}")
            }
            _ => {}
        }
        let action = mac_reachability_action(got).map(|a| match a {
            MacRecoveryActionKind::Retry => "Retry",
            MacRecoveryActionKind::SignIn => "SignIn",
        });
        assert_eq!(action, c["action"].as_str(), "{name}: action");
        seen.insert(kind_name(&got).to_string());
    }
    let all: BTreeSet<_> = names(&f, "reachability_kinds").into_iter().collect();
    assert_eq!(seen, all, "a reachability kind no case reaches");
    assert_eq!(mac_reachability_span(40), "40 s");
}

#[test]
fn every_protocol_version_matches_and_names_its_old_peer_tests() {
    let f = fixture();
    let multipath = std::fs::read_to_string(
        crates_dir().join("cmux-mobile-link/src/dial/wireguard_multipath.rs"),
    )
    .unwrap();
    for v in f["versions"].as_array().unwrap() {
        let name = v["name"].as_str().unwrap();
        let actual: Option<u32> = match name {
            "WG_VERSION" => Some(cmux_mobile_link::signaling::WG_VERSION),
            "WG_REACH_VERSION" => Some(cmux_mobile_link::signaling::WG_REACH_VERSION),
            "AD_VERSION" => Some(cmux_mobile_link::local::AD_VERSION),
            "HUB_VERSION" => Some(cmux_mobile_link::local::HUB_VERSION),
            // Private to the dial module: read from its source.
            "MULTIPATH_VERSION" => multipath
                .lines()
                .find_map(|l| l.trim().strip_prefix("pub const MULTIPATH_VERSION: u32 = "))
                .map(|s| s.trim_end_matches(';').parse().unwrap()),
            _ => None,
        };
        assert_eq!(actual.map(u64::from), v["value"].as_u64(), "{name}: bump it here and in iOS");
        let guards = v["guards"].as_array().unwrap();
        assert!(!guards.is_empty(), "{name}: no old-peer test");
        for g in guards {
            let file = g[0].as_str().unwrap();
            let func = g[1].as_str().unwrap();
            let src = std::fs::read_to_string(crates_dir().join(file))
                .unwrap_or_else(|_| panic!("{name}: {file} is gone"));
            assert!(src.contains(&format!("fn {func}(")), "{name}: {file} lost fn {func}");
        }
    }
}
