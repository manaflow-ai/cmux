#[test]
fn vm_host_line_says_why() {
    use serde_json::json;
    let v = json!({"vmHost": true, "cmuxVm": true, "configured": null});
    assert_eq!(
        super::vm_host_line(None, &v),
        "this machine: vmHost on (unsandboxed only for its owner's own sessions, when the Cloud API says so)"
    );
    let v = json!({"vmHost": false, "cmuxVm": true, "configured": false});
    assert_eq!(
        super::vm_host_line(Some("cloud-a"), &v),
        "cloud-a: vmHost off (turned off in its config)"
    );
    // A Mac: its Seatbelt sandbox always runs.
    let v = json!({"vmHost": false, "cmuxVm": false, "configured": null});
    assert_eq!(super::vm_host_line(None, &v), "this machine: vmHost off (always sandboxed here)");
}

use super::*;
use serde_json::json;

#[test]
fn outdated_hint_names_the_peer_and_avoids_cross_platform_update() {
    let other_os = if std::env::consts::OS == "linux" { "macos" } else { "linux" };
    let other = json!({"outdated": true, "os": other_os, "arch": std::env::consts::ARCH});
    let hint = outdated_hint("my-linux", &other).unwrap();
    assert!(hint.contains("acpmux machine update my-linux --binary-dir DIR"), "{hint}");
    assert!(hint.contains("DIR/acpmux-"), "{hint}");
    assert!(hint.contains("or rebuild acpmux on my-linux for its OS and architecture"), "{hint}");
    let same =
        json!({"outdated": true, "os": std::env::consts::OS, "arch": std::env::consts::ARCH});
    assert_eq!(
        outdated_hint("same", &same).as_deref(),
        Some("  (differs from this build: acpmux machine update same)")
    );
    let nested =
        json!({"outdated": true, "health": {"os": other_os, "arch": std::env::consts::ARCH}});
    assert!(
        outdated_hint("nested-linux", &nested)
            .unwrap()
            .contains("acpmux machine update nested-linux --binary-dir DIR")
    );
    let unknown = json!({"outdated": true, "health": {"cpus": 4}});
    let hint = outdated_hint("unknown-platform", &unknown).unwrap();
    assert!(hint.contains("peer target unknown"), "{hint}");
    assert!(hint.contains("only with a matching build"), "{hint}");
    assert!(hint.contains("or rebuild acpmux on unknown-platform"), "{hint}");
}

#[test]
fn a_reachable_peer_reads_its_numbers_and_an_unreachable_one_its_next_step() {
    let reply = json!({"hosts": [
        {"name": "huge-blue", "self": true, "reachable": true, "cpus": 32, "load": [3.2, 2.0, 1.0],
         "disk": {"freeBytes": 25_000_000_000u64, "totalBytes": 252_000_000_000u64},
         "ram": {"freeBytes": 40_000_000_000u64, "totalBytes": 128_000_000_000u64},
         "liveSessions": 9, "build": "abc"},
        {"name": "big-red", "self": false, "reachable": false,
         "error": "connection refused; `acpmux machine doctor big-red` checks it step by step"},
        {"name": "cmux16", "self": false, "reachable": true, "latencyMs": 41, "outdated": true,
         "build": "old", "os": std::env::consts::OS, "arch": std::env::consts::ARCH},
    ]});
    let l = lines(&reply);
    assert_eq!(
        l[0],
        "huge-blue (this)     ok  disk 25.0 GB free of 252.0 GB  ram 40.0 GB free of 128.0 GB  load 3.2/32 cpus  9 live sessions  build abc"
    );
    assert!(l[1].starts_with("big-red              unreachable  connection refused;"), "{}", l[1]);
    assert!(l[1].ends_with("`acpmux machine doctor big-red` checks it step by step"), "{}", l[1]);
    assert!(l[2].contains("41 ms") && l[2].contains("acpmux machine update cmux16"), "{}", l[2]);
    assert_eq!(l.len(), 3, "no problems, no extra lines: {l:?}");
}

#[test]
fn host_status_prints_each_problem_under_its_machine() {
    let reply = json!({"hosts": [
        {"name": "huge-blue", "self": false, "reachable": true, "latencyMs": 12,
         "problems": [
            {"check": "dns", "detail": "DNS: github.com does not resolve",
             "since": "2026-10-25T11:40:00.000Z"},
            {"check": "loop", "detail": "machine health check has not run since 2026-10-25T11:50:00.000Z"},
            {"check": 7, "detail": "a bad entry"}]},
        {"name": "cmux16", "self": false, "reachable": true, "latencyMs": 41, "problems": []},
    ]});
    let l = lines(&reply);
    assert_eq!(l.len(), 4, "{l:?}");
    assert!(l[0].starts_with("huge-blue"), "{}", l[0]);
    assert_eq!(
        l[1],
        "  problem DNS: DNS: github.com does not resolve (since 2026-10-25T11:40:00.000Z)"
    );
    assert_eq!(
        l[2],
        "  problem health check: machine health check has not run since 2026-10-25T11:50:00.000Z"
    );
    assert!(l[3].starts_with("cmux16"), "{}", l[3]);
}

#[test]
fn a_disk_problem_says_its_severity_and_a_cmux_tui_one_its_name() {
    let reply = json!({"hosts": [{"name": "devbox", "self": true, "reachable": true, "problems": [
            {"check": "disk", "detail": "disk: CRITICAL: 1.0 GB free on /", "severity": "critical"},
            {"check": "disk", "detail": "disk: 9.0 GB free on /", "severity": "loud"},
            {"check": "cmux", "detail": "cmux: cmux-tui-daemon.service failed"}]}]});
    let l = lines(&reply);
    assert_eq!(l[1], "  problem disk (critical): disk: CRITICAL: 1.0 GB free on /");
    assert_eq!(l[2], "  problem disk: disk: 9.0 GB free on /");
    assert_eq!(l[3], "  problem cmux-tui: cmux: cmux-tui-daemon.service failed");
}

#[test]
fn a_host_ls_row_reads_the_last_health_and_an_old_peer_reads_unknown() {
    let p = json!({"health": {"cpus": 16, "load": [9.5, 4.0, 2.0],
            "ram": {"freeBytes": 12_000_000_000u64, "totalBytes": 64_000_000_000u64},
            "disk": {"freeBytes": 80_000_000_000u64}, "liveSessions": 4,
            "pressure": {"ok": false}}});
    assert_eq!(
        resources(&p),
        "ram 12.0 GB free  load 9.5/16  disk 80.0 GB free  4 live  over budget"
    );
    let p = json!({"health": {"disk": {"freeBytes": 31_000_000_000u64}, "problems": [
            {"check": "dns", "detail": "DNS: github.com does not resolve"},
            {"check": "peer", "detail": "peer cosmic-gray: handshake not finished"},
            {"check": "dns", "detail": "DNS: api.github.com does not resolve"},
            {"detail": "no check"}]}});
    assert_eq!(resources(&p), "disk 31.0 GB free  problems: DNS, peer link");
    let healthy = json!({"health": {"disk": {"freeBytes": 31_000_000_000u64}, "problems": []}});
    assert_eq!(resources(&healthy), "disk 31.0 GB free");
    assert_eq!(resources(&json!({"health": {"unsupported": true}})), "resources unknown");
    assert_eq!(resources(&json!({"health": null})), "resources unknown");
}
