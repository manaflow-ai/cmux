//! The phone's app-level API contract (cmux-next-ios/contract/README.md, "App-level API").
//!
//! Leo: "well clearly we need to be able to support the multiple versions as it goes".
//! This fails when:
//! - `cmux-mobile-api/phone-api.json` is not what the protocol IRs and hostd's allow lists
//!   build (`CMUX_UPDATE_PHONE_API=1` rewrites it and the surface snapshot);
//! - a method a phone uses changed in a way an older phone or Mac cannot read, and
//!   `phone-api.compat.json` has no rule for it;
//! - a daemon command hostd lets a phone send has no schema;
//! - the Swift app names an acpmux method hostd does not list;
//! - hostd serves a link service the list does not name.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use cmux_mobile_api::lower::{Inputs, build};
use cmux_mobile_host::api::{LINK_SERVICES, PHONE_ACPMUX_METHODS};
use cmux_mobile_host::policy::ALLOWED_COMMANDS;
use serde_json::Value;

fn repo() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../..")
}

fn api_crate() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../cmux-mobile-api")
}

fn read_json(path: &Path) -> Value {
    let bytes = std::fs::read(path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
    serde_json::from_slice(&bytes).unwrap_or_else(|e| panic!("parse {}: {e}", path.display()))
}

fn update() -> bool {
    std::env::var_os("CMUX_UPDATE_PHONE_API").is_some()
}

fn generated() -> Value {
    let sdk = read_json(&repo().join("cmux-tui/spec/sdk-schema.json"));
    let acpmux = read_json(&repo().join("cmux-tui/crates/acpmux/spec/acpmux-protocol.json"));
    let daemon_commands: BTreeSet<&str> = ALLOWED_COMMANDS.iter().copied().collect();
    let acpmux_methods: BTreeSet<&str> = PHONE_ACPMUX_METHODS.iter().copied().collect();
    let inputs = Inputs {
        sdk: &sdk,
        acpmux: &acpmux,
        daemon_commands: &daemon_commands,
        acpmux_methods: &acpmux_methods,
        services: LINK_SERVICES,
    };
    build(&inputs).unwrap_or_else(|problems| panic!("phone API contract:\n  - {}", problems.join("\n  - ")))
}

#[test]
fn committed_contract_is_generated_and_compatible() {
    let fresh = generated();
    let path = api_crate().join("phone-api.json");
    let mut text = serde_json::to_string_pretty(&fresh).unwrap();
    text.push('\n');
    if update() {
        std::fs::write(&path, &text).unwrap();
    } else {
        let committed = std::fs::read_to_string(&path).unwrap_or_default();
        assert!(
            committed == text,
            "{} is stale: a daemon command, acpmux method or link service a phone uses changed. \
             Run CMUX_UPDATE_PHONE_API=1 cargo test -p cmux-mobile-host --test phone_api_contract \
             and commit the result (a breaking change also needs a rule in phone-api.compat.json).",
            path.display()
        );
    }
    let outcome = cmux_api_compat::json_schema::check_files(
        &fresh,
        &api_crate().join("phone-api.surface.json"),
        &api_crate().join("phone-api.compat.json"),
        update(),
    )
    .unwrap();
    assert!(
        outcome.ok,
        "phone API compat: {}\n(here: add the revision to cmux-next-ios/rust/crates/cmux-mobile-api/phone-api.compat.json, \
         make the phone and hostd honor it, then CMUX_UPDATE_PHONE_API=1 cargo test -p cmux-mobile-host --test phone_api_contract)",
        outcome.message
    );
}

#[test]
fn swift_app_uses_only_listed_acpmux_methods() {
    let sources = repo().join("cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileLive");
    if !sources.is_dir() {
        eprintln!("skipped: {} is not checked out", sources.display());
        return;
    }
    let listed: BTreeSet<&str> = PHONE_ACPMUX_METHODS.iter().copied().collect();
    let mut unlisted = BTreeSet::new();
    let mut stack = vec![sources];
    while let Some(dir) = stack.pop() {
        for entry in std::fs::read_dir(&dir).unwrap().flatten() {
            let path = entry.path();
            if path.is_dir() {
                stack.push(path);
            } else if path.extension().is_some_and(|e| e == "swift") {
                let text = std::fs::read_to_string(&path).unwrap_or_default();
                for literal in text.split('"').skip(1).step_by(2) {
                    let method = literal.starts_with("_acpmux/")
                        || literal.starts_with("session/")
                        || literal.starts_with("acp.session.");
                    let word = literal.bytes().all(|b| b.is_ascii_lowercase() || b"_/.".contains(&b));
                    if method && word && literal.len() > 8 && !listed.contains(literal) {
                        unlisted.insert(format!("{literal} ({})", path.display()));
                    }
                }
            }
        }
    }
    assert!(
        unlisted.is_empty(),
        "the Swift app names acpmux methods hostd does not list in api.rs PHONE_ACPMUX_METHODS:\n  - {}",
        unlisted.into_iter().collect::<Vec<_>>().join("\n  - ")
    );
}

#[test]
fn every_served_link_service_is_listed() {
    let services =
        std::fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join("src/services.rs")).unwrap();
    let start = services.find("let result = match service.as_str() {").expect("services.rs dispatch");
    let end = start + services[start..].find("unknown_service").expect("dispatch end");
    let listed: BTreeSet<&str> = LINK_SERVICES.iter().map(|s| s.name).collect();
    let mut missing = Vec::new();
    for line in services[start..end].lines() {
        let arm = line.trim_start();
        if let Some(rest) = arm.strip_prefix('"')
            && let Some((name, tail)) = rest.split_once('"')
            && tail.trim_start().starts_with("=>")
            && !listed.contains(name)
        {
            missing.push(name.to_owned());
        }
    }
    assert!(missing.is_empty(), "services.rs serves {missing:?}, which api.rs LINK_SERVICES does not list");
    let mut seen = BTreeSet::new();
    for service in LINK_SERVICES {
        assert!(seen.insert(service.name), "{} is listed twice", service.name);
    }
}

#[test]
fn strict_daemon_lines_refuse_unknown_fields() {
    use cmux_mobile_host::policy::{DaemonPolicy, Verdict};
    let line = br#"{"id":1,"cmd":"list-workspaces","not_a_field":true}"#;
    match DaemonPolicy::new("phone").with_strict(true).evaluate(line) {
        Verdict::Refuse(reply) => assert!(reply.contains("unknown_field"), "{reply}"),
        other => panic!("strict policy forwarded an unknown field: {other:?}"),
    }
    // Without `strict` an older phone's line still goes on (the daemon has the last word).
    assert_eq!(DaemonPolicy::new("phone").evaluate(line), Verdict::Forward);
    assert_eq!(
        DaemonPolicy::new("phone").with_strict(true).evaluate(br#"{"id":1,"cmd":"list-workspaces"}"#),
        Verdict::Forward
    );
}
