//! The agent-host record crosses an update (cmux-tui/persisted-formats/formats.toml,
//! `agent-host-record`). A live agent host outlives the daemon that started it: the next daemon
//! adopts it by the record the old build wrote, and `load_records` sets aside any record whose
//! `record_version` is not this build's. So every shape an older build wrote must still load,
//! and a change to the shape this build writes ships with a fixture of it.
//!
//! Leo, 2026-11-24 (ask-1f9e8b7422): "we need to make sure in the future these kinds of cutovers
//! always have proper migrations. in the future."

use super::*;
use std::collections::BTreeSet;
use std::os::unix::fs::PermissionsExt;

const FIXTURES: &str =
    concat!(env!("CARGO_MANIFEST_DIR"), "/../../persisted-formats/agent-host-record");

/// `(version, revision, path)` of each fixture, oldest first: `v1.json` is `(1, 1)`, `v1-2.json`
/// is `(1, 2)`.
fn fixtures() -> Vec<(u32, u32, PathBuf)> {
    let mut out = Vec::new();
    for entry in std::fs::read_dir(FIXTURES).expect("read the agent-host-record fixtures") {
        let path = entry.unwrap().path();
        let stem = path.file_stem().and_then(|s| s.to_str()).unwrap_or_default().to_owned();
        let Some(rest) = stem.strip_prefix('v') else { continue };
        let (version, revision) = match rest.split_once('-') {
            Some((v, r)) => (v.parse().unwrap(), r.parse().unwrap()),
            None => (rest.parse().unwrap(), 1),
        };
        out.push((version, revision, path));
    }
    out.sort();
    out
}

fn keys(value: &Value) -> BTreeSet<String> {
    value.as_object().expect("a record is a JSON object").keys().cloned().collect()
}

/// Every field set, every option `Some`, every flag on: the whole shape this build writes. A new
/// field fails to compile here until it is named, and then fails below until the fixture folder
/// has its shape.
fn whole_record() -> HostRecord {
    HostRecord {
        record_version: RECORD_VERSION,
        session_id: "s".into(),
        incarnation: "i".into(),
        host_pid: 1,
        start_nonce: "00".into(),
        harness_pid: Some(2),
        owner_token: "o".into(),
        caller_token: Some("c".into()),
        protocol_min: PROTOCOL_MIN,
        protocol_max: PROTOCOL_MAX,
        host_build: "b".into(),
        socket: PathBuf::from("/s.sock"),
        claude_translator: true,
        host_level: HOST_LEVEL,
        holder: Some(false),
        local_chatgpt_expiry: Some(1_800_000_000),
        local_kimi_expiry: Some(1_800_000_001),
    }
}

#[test]
fn cmux_next_persisted_agent_host_record_every_older_shape_loads() {
    let all = fixtures();
    assert!(
        all.iter().any(|(v, _, _)| *v == RECORD_VERSION),
        "no fixture of agent-host record version {RECORD_VERSION} in {FIXTURES}: a version raise \
         ships with a fixture of the new shape (and keeps the old ones)"
    );
    for (version, revision, path) in all {
        let dir = tempfile::tempdir().unwrap();
        std::fs::set_permissions(dir.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        let session = "chat-persisted-format";
        let socket = socket_path(dir.path(), session);
        let text = std::fs::read_to_string(&path)
            .unwrap()
            .replace("@SESSION@", session)
            .replace("@SOCKET@", &socket.to_string_lossy());
        let record_path = dir.path().join(format!("{session}.json"));
        std::fs::write(&record_path, &text).unwrap();
        std::fs::set_permissions(&record_path, std::fs::Permissions::from_mode(0o600)).unwrap();

        let (good, bad) = load_records(dir.path()).unwrap();
        assert!(
            bad.is_empty() && good.len() == 1,
            "{}: the next daemon does not adopt a host whose record an older build wrote \
             (v{version}-{revision}): {:?}. Keep reading the old shape, or convert it, before shipping",
            path.display(),
            bad.iter().map(|b| b.reason.as_str()).collect::<Vec<_>>()
        );
        let record = &good[0].1;
        assert_eq!(record.record_version, version, "{}", path.display());
        // Nothing the old build wrote is dropped on the way in.
        let read_back = serde_json::to_value(record).unwrap();
        let fixture: Value = serde_json::from_str(&text).unwrap();
        for (key, value) in fixture.as_object().unwrap() {
            assert_eq!(
                read_back.get(key),
                Some(value),
                "{}: field `{key}` does not survive a read by this build",
                path.display()
            );
        }
    }
}

#[test]
fn cmux_next_persisted_agent_host_record_writer_shape_has_a_fixture() {
    let all = fixtures();
    let (version, revision, newest) = all.last().expect("fixtures").clone();
    assert_eq!(version, RECORD_VERSION, "the newest fixture is not this build's version");
    let fixture: Value = serde_json::from_str(&std::fs::read_to_string(&newest).unwrap()).unwrap();
    let written = serde_json::to_value(whole_record()).unwrap();
    assert_eq!(
        keys(&written),
        keys(&fixture),
        "the agent-host record this build writes is not the shape of {} (v{version}-{revision}). \
         Add v{version}-{next}.json with the new shape (never edit an old fixture) and keep the old ones \
         loading; raising RECORD_VERSION also needs load_records to keep adopting the old version \
         (cmux-tui/persisted-formats/formats.toml)",
        newest.display(),
        next = revision + 1
    );
}
