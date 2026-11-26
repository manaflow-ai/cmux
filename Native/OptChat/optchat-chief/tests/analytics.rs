//! Chief product analytics (src/analytics, docs/posthog/chief-product-analytics.md):
//! the event catalog, the privacy rules (no text, path, id or secret leaves),
//! consent, the offline queue and the PostHog batch request.

use std::collections::BTreeMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, mpsc};
use std::time::Duration;

use optchat_chief::analytics::catalog::{self, State};
use optchat_chief::analytics::consent::{self, Consent, Inputs};
use optchat_chief::analytics::{Analytics, Config};
use optchat_chief::trace::Trace;
use serde_json::{Value, json};

/// Strings that must never appear in anything sent.
const SECRETS: [&str; 6] = [
    "sk-ant-api03-SEEDEDSECRETVALUE",
    "ghp_SEEDEDGITHUBTOKEN0123456789",
    "lawrence@manaflow.ai",
    "/Users/lawrence/secret-project",
    "please fix the login bug",
    "zz-a1234",
];

fn seeded_text() -> String {
    SECRETS.join(" ")
}

fn trace_text(t: &Trace, text: &str) -> Value {
    t.text(text)
}

/// Trace events as the host writes them, with every free-text field seeded.
fn seeded_events(t: &Trace) -> Vec<Value> {
    let secret = seeded_text();
    vec![
        json!({"ev": "usage.message", "ts": 1_800_000_000_000u64, "id": "zz-a1234", "person": "lawrence@manaflow.ai",
               "from": "human", "images": true, "files": false, "remote": false, "side": false}),
        json!({"ev": "turn.end", "ts": 1_800_000_001_000u64, "turn": "turn:zz-a1234", "ms": 5_000, "status": "error",
               "harness": "claude", "model": "claude-opus-5-5", "effort": "high", "tier": 2,
               "route": secret, "error": trace_text(t, &format!("429 rate limit {secret}")),
               "reply": trace_text(t, &secret), "usage": {"input": 100, "cache_read": 900, "cache_write": 0, "output": 50},
               "cost_usd": 0.0123456789, "requests": 2, "tools": 3, "tool_errors": 1, "start_ms": 300, "ttft_ms": 1200,
               "harness_kind": "acp", "harness_argv0": secret, "harness_profile": secret}),
        json!({"ev": "turn.end", "ts": 1_800_000_002_000u64, "turn": "t2", "ms": 4_000, "status": "ok",
               "harness": secret, "model": secret, "reply": trace_text(t, "done"), "usage": null}),
        json!({"ev": "tool", "ts": 1_800_000_003_000u64, "turn": "t2", "name": "mcp__optchat__send", "args_bytes": 10}),
        json!({"ev": "tool", "ts": 1_800_000_003_100u64, "turn": "t2", "name": format!("mcp__{secret}__x")}),
        json!({"ev": "tool", "ts": 1_800_000_003_200u64, "turn": "t2", "name": "Bash"}),
        json!({"ev": "tool", "ts": 1_800_000_003_300u64, "turn": "t2", "name": "Bash"}),
        json!({"ev": "spawn", "ts": 1_800_000_004_000u64, "spawn": "s1", "ids": ["zz-a1234", "zz-a1235"],
               "tasks": [trace_text(t, &secret)], "harness": "codex",
               "placements": [{"id": "zz-a1234", "place": "here"}, {"id": "zz-a1235", "place": "lawrence-mac"}]}),
        json!({"ev": "subagent.start", "ts": 1_800_000_005_000u64, "id": "zz-a1234", "session": secret, "harness": "codex",
               "harness_kind": "acp", "goal": true, "ms": 900}),
        json!({"ev": "subagent.done", "ts": 1_800_000_006_000u64, "id": "zz-a1234", "report": trace_text(t, &secret),
               "ms": 60_000, "tools": 40, "tool_errors": 2, "stopped": false, "landed": true, "unlanded": false}),
        json!({"ev": "harness.refused", "ts": 1_800_000_007_000u64, "role": "subagent", "harness": "claude", "reason": secret}),
        json!({"ev": "node", "ts": 1_800_000_008_000u64, "node": "5236+4", "harness": "claude", "ok": false,
               "error": trace_text(t, &format!("overloaded {secret}")), "ms": 2000}),
    ]
}

#[test]
fn the_catalog_maps_trace_events_and_never_copies_text() {
    let t = Trace::off();
    let mut state = State {
        installed_ms: 1_800_000_000_000,
        ..State::default()
    };
    let mut names = Vec::new();
    let mut all = String::new();
    for e in seeded_events(&t) {
        let ts = e["ts"].as_u64().unwrap();
        for out in catalog::map(&e, &mut state, ts) {
            assert!(
                catalog::EVENTS.contains(&out.name),
                "{} is not in the catalog",
                out.name
            );
            all.push_str(&Value::Object(out.properties.clone()).to_string());
            names.push((out.name, out.properties));
        }
    }
    for secret in SECRETS {
        assert!(!all.contains(secret), "{secret:?} leaked: {all}");
    }
    let find = |name: &str| {
        names
            .iter()
            .filter(|(n, _)| *n == name)
            .map(|(_, p)| p)
            .collect::<Vec<_>>()
    };
    let turns = find("chief_turn_completed");
    assert_eq!(turns.len(), 2);
    assert_eq!(turns[0]["turn_status"], "error");
    assert_eq!(turns[0]["error_class"], "rate_limited");
    assert_eq!(turns[0]["model"], "claude-opus-5-5");
    assert_eq!(turns[0]["cache_hit_rate"], 0.9);
    assert_eq!(turns[0]["cost_usd"], 0.012346);
    assert_eq!(turns[1]["harness"], "other");
    assert_eq!(turns[1]["model"], "other");
    // First use per day: send, an unknown MCP server's tool, Bash once.
    let tools: Vec<_> = find("chief_tool_used")
        .iter()
        .map(|p| p["tool"].clone())
        .collect();
    assert_eq!(
        tools,
        vec![json!("send"), json!("mcp_other"), json!("bash")]
    );
    let spawned = find("chief_subagents_spawned");
    assert_eq!(
        (
            spawned[0]["count"].clone(),
            spawned[0]["here"].clone(),
            spawned[0]["peer"].clone()
        ),
        (json!(2), json!(1), json!(1))
    );
    assert_eq!(find("chief_subagent_finished")[0]["outcome"], "landed");
    assert_eq!(find("chief_error")[0]["kind"], "harness_refused");
    assert_eq!(
        find("chief_compactor_failed")[0]["error_class"],
        "overloaded"
    );
    assert_eq!(find("chief_daily_active").len(), 1);
    let milestones: Vec<_> = find("chief_activation_milestone_reached")
        .iter()
        .map(|p| p["milestone"].clone())
        .collect();
    assert_eq!(
        milestones,
        vec![
            json!("first_message"),
            json!("first_reply"),
            json!("first_subagent"),
            json!("first_subagent_done"),
            json!("first_landed_work")
        ]
    );
    // A milestone goes once per install.
    let again = catalog::map(&seeded_events(&t)[0], &mut state, 1_800_000_009_000);
    assert!(
        again
            .iter()
            .all(|e| e.name != "chief_activation_milestone_reached")
    );
}

#[test]
fn closed_tokens_refuse_free_text() {
    assert_eq!(
        catalog::model(Some("claude-sonnet-5[1m]")),
        "claude-sonnet-5"
    );
    assert_eq!(catalog::model(Some("gpt-5.5-codex")), "gpt-5.5-codex");
    assert_eq!(catalog::model(Some("my-private-finetune")), "other");
    assert_eq!(catalog::model(Some("claude-/Users/x")), "other");
    assert_eq!(catalog::model(None), "default");
    assert_eq!(catalog::harness(Some("claude-sr")), "claude-sr");
    assert_eq!(catalog::harness(Some("/usr/local/bin/claude")), "other");
    assert_eq!(catalog::effort(Some("xhigh")), "xhigh");
    assert_eq!(catalog::tool(Some("mcp__cmux__browser")), "mcp_cmux");
    assert_eq!(
        catalog::error_class("Error: connection reset by peer"),
        "network"
    );
    assert_eq!(
        catalog::error_class("prompt is too long: 250000 tokens"),
        "context_too_long"
    );
    assert_eq!(catalog::error_class("something odd"), "other");
}

#[test]
fn landed_reads_commit_ranges_and_unlanded_words() {
    use optchat_chief::sub_watch::landed;
    assert!(landed("Landed 1a2b3c4..5d6e7f8 on feat-cmux-next"));
    assert!(landed("landed as abc1234 on the branch"));
    assert!(!landed("Fix is unpushed: abc1234"));
    assert!(!landed("nothing committed, a question answered"));
    assert!(!landed("not landed: abc1234 is red"));
}

#[test]
fn consent_sends_only_after_the_person_turns_it_on() {
    let none = BTreeMap::new();
    let no_env = |_: &str| None;
    let base = |forced: &'static BTreeMap<String, Value>,
                settings: Option<&'static Value>,
                release: bool,
                env: &'static dyn Fn(&str) -> Option<String>| {
        consent::decide(&Inputs {
            managed_forced: forced,
            settings,
            app_choice: None,
            release_build: release,
            env,
        })
    };
    let none: &'static BTreeMap<String, Value> = Box::leak(Box::new(none));
    let no_env: &'static dyn Fn(&str) -> Option<String> = Box::leak(Box::new(no_env));
    // A fresh install (no choice anywhere) sends nothing: analytics are opt-in.
    assert_eq!(
        base(none, None, true, no_env),
        Consent::Off("anonymous telemetry was never turned on")
    );
    let on: &'static Value = Box::leak(Box::new(json!({"app": {"sendAnonymousTelemetry": true}})));
    assert_eq!(
        base(none, Some(on), true, no_env),
        Consent::Send("production")
    );
    let app_on = consent::decide(&Inputs {
        managed_forced: none,
        settings: None,
        app_choice: Some(true),
        release_build: true,
        env: no_env,
    });
    assert_eq!(app_on, Consent::Send("production"));
    assert!(
        matches!(base(none, Some(on), false, no_env), Consent::Off(_)),
        "debug and DEV builds stay off"
    );
    let forced: &'static BTreeMap<String, Value> = Box::leak(Box::new(BTreeMap::from([(
        "DisableTelemetry".to_owned(),
        json!(true),
    )])));
    assert_eq!(
        base(forced, Some(on), true, no_env),
        Consent::Off("managed policy DisableTelemetry")
    );
    let off: &'static Value =
        Box::leak(Box::new(json!({"app": {"sendAnonymousTelemetry": false}})));
    assert_eq!(
        base(none, Some(off), true, no_env),
        Consent::Off("app.sendAnonymousTelemetry is false")
    );
    let dnt: &'static dyn Fn(&str) -> Option<String> = Box::leak(Box::new(|k: &str| {
        (k == "DO_NOT_TRACK").then(|| "1".to_owned())
    }));
    assert_eq!(
        base(none, Some(on), true, dnt),
        Consent::Off("DO_NOT_TRACK")
    );
    let chief_off: &'static dyn Fn(&str) -> Option<String> = Box::leak(Box::new(|k: &str| {
        (k == "CMUX_CHIEF_ANALYTICS").then(|| "off".to_owned())
    }));
    assert_eq!(
        base(none, Some(on), true, chief_off),
        Consent::Off("CMUX_CHIEF_ANALYTICS=off")
    );
    let ci: &'static dyn Fn(&str) -> Option<String> =
        Box::leak(Box::new(|k: &str| (k == "CI").then(|| "true".to_owned())));
    assert_eq!(base(none, Some(on), true, ci), Consent::Off("CI"));
    let dev: &'static dyn Fn(&str) -> Option<String> = Box::leak(Box::new(|k: &str| {
        (k == "CMUX_CHIEF_ANALYTICS").then(|| "dev".to_owned())
    }));
    assert_eq!(base(none, None, false, dev), Consent::Send("dev"));
    // The app's own choice, read from its preferences on every check.
    let app_off = consent::decide(&Inputs {
        managed_forced: none,
        settings: None,
        app_choice: Some(false),
        release_build: true,
        env: no_env,
    });
    assert_eq!(
        app_off,
        Consent::Off("the app's sendAnonymousTelemetry is off")
    );
    // The managed policy wins over the dev switch.
    assert!(matches!(base(forced, None, false, dev), Consent::Off(_)));
}

#[test]
fn the_channel_comes_from_the_app_or_the_bundle() {
    use optchat_chief::analytics::channel;
    use std::path::Path;
    let none = |_: &str| None;
    let bin = |app: &str| format!("/Applications/{app}/Contents/Resources/bin/optchat-chief");
    assert_eq!(
        channel("local", &none, Some(Path::new(&bin("cmux NIGHTLY.app")))),
        "nightly"
    );
    assert_eq!(
        channel("local", &none, Some(Path::new(&bin("cmux.app")))),
        "stable"
    );
    assert_eq!(
        channel("local", &none, Some(Path::new(&bin("cmux DEV my-tag.app")))),
        "dev"
    );
    assert_eq!(
        channel(
            "local",
            &none,
            Some(Path::new("/usr/local/bin/optchat-chief"))
        ),
        "cli"
    );
    assert_eq!(channel("cloud", &none, None), "cloud");
    let app = |k: &str| (k == "CMUX_CHIEF_APP_BUNDLE_ID").then(|| "com.cmuxterm.app.rc".to_owned());
    assert_eq!(channel("local", &app, None), "rc");
    let tagged = |k: &str| {
        (k == "CMUX_CHIEF_APP_BUNDLE_ID").then(|| "com.cmuxterm.app.debug.my-tag".to_owned())
    };
    assert_eq!(channel("local", &tagged, None), "dev");
}

/// A one-connection-at-a-time HTTP server that records each POST body and
/// answers `status`.
fn server(status: u16) -> (String, mpsc::Receiver<Value>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}/batch/", listener.local_addr().unwrap());
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut length = 0usize;
            loop {
                let mut line = String::new();
                if reader.read_line(&mut line).unwrap_or(0) == 0 || line == "\r\n" {
                    break;
                }
                if let Some(v) = line.to_ascii_lowercase().strip_prefix("content-length:") {
                    length = v.trim().parse().unwrap_or(0);
                }
            }
            let mut body = vec![0; length];
            let _ = reader.read_exact(&mut body);
            if let Ok(v) = serde_json::from_slice::<Value>(&body) {
                let _ = tx.send(v);
            }
            let _ = write!(
                stream,
                "HTTP/1.1 {status} X\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{{}}"
            );
        }
    });
    (url, rx)
}

fn config(endpoint: String) -> Config {
    Config {
        source: "local",
        build: "0123456789abcdef".into(),
        channel: "nightly".into(),
        engine: "acpmux",
        endpoint,
        ..Config::default()
    }
}

#[test]
fn a_host_sends_one_batch_with_no_text_and_the_shared_properties() {
    let (url, rx) = server(200);
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("optchat");
    let trace = Trace::open(&root.join("traces"), false).unwrap();
    let analytics = Analytics::open(&root, config(url), || Consent::Send("dev")).unwrap();
    trace.set_analytics(analytics.clone());
    for e in seeded_events(&trace) {
        let ev = e["ev"].as_str().unwrap().to_owned();
        let mut fields = e.clone();
        fields.as_object_mut().unwrap().remove("ev");
        fields.as_object_mut().unwrap().remove("ts");
        trace.emit(&ev, fields);
    }
    assert!(analytics.flush().unwrap() > 0);
    let body = rx.recv_timeout(Duration::from_secs(10)).unwrap();
    let text = body.to_string();
    for secret in SECRETS {
        assert!(!text.contains(secret), "{secret:?} was sent: {text}");
    }
    assert_eq!(body["api_key"], optchat_chief::analytics::PROJECT_KEY);
    let batch = body["batch"].as_array().unwrap();
    let names: Vec<_> = batch.iter().map(|e| e["event"].as_str().unwrap()).collect();
    assert!(names.contains(&"chief_host_started"), "{names:?}");
    assert!(names.contains(&"chief_turn_completed"), "{names:?}");
    let id = std::fs::read_to_string(root.join("analytics/id")).unwrap();
    for e in batch {
        let p = &e["properties"];
        assert_eq!(p["distinct_id"], id.trim());
        assert_eq!(p["environment"], "dev");
        assert_eq!(p["channel"], "nightly");
        assert_eq!(p["$geoip_disable"], true);
        assert_eq!(p["product"], "chief");
        assert_eq!(e["uuid"].as_str().unwrap().len(), 36);
    }
    // The queue is empty after a send.
    assert!(!root.join("analytics/queue.jsonl").exists());
    assert!(!root.join("analytics/sending.jsonl").exists());
    // Files are private.
    use std::os::unix::fs::PermissionsExt;
    let mode = std::fs::metadata(root.join("analytics"))
        .unwrap()
        .permissions()
        .mode()
        & 0o777;
    assert_eq!(mode, 0o700);
}

#[test]
fn offline_keeps_the_queue_and_sends_it_later() {
    // Nothing listens on a port bound and dropped.
    // Port 9 (discard) has no listener on a test host.
    let dead = "http://127.0.0.1:9/batch/".to_owned();
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("optchat");
    let analytics = Analytics::open(&root, config(dead), || Consent::Send("dev")).unwrap();
    assert!(analytics.flush().is_err());
    let kept = std::fs::read_to_string(root.join("analytics/sending.jsonl")).unwrap();
    assert!(kept.contains("chief_host_started"));
    drop(analytics);
    // The next host on the same root sends the kept batch first.
    let (url, rx) = server(200);
    let analytics = Analytics::open(&root, config(url), || Consent::Send("dev")).unwrap();
    assert!(analytics.flush().unwrap() >= 2);
    let mut names = Vec::new();
    while let Ok(body) = rx.recv_timeout(Duration::from_secs(5)) {
        names.extend(
            body["batch"]
                .as_array()
                .unwrap()
                .iter()
                .map(|e| e["event"].as_str().unwrap().to_owned()),
        );
        if names.iter().filter(|n| *n == "chief_host_started").count() >= 2 {
            break;
        }
    }
    assert_eq!(
        names.iter().filter(|n| *n == "chief_host_started").count(),
        2,
        "{names:?}"
    );
    assert!(!root.join("analytics/sending.jsonl").exists());
}

/// A consent function that reads `on`.
fn switch(on: &Arc<AtomicBool>) -> impl Fn() -> Consent + Send + 'static {
    let on = on.clone();
    move || {
        if on.load(Ordering::SeqCst) {
            Consent::Send("dev")
        } else {
            Consent::Off("test")
        }
    }
}

#[test]
fn turning_telemetry_off_deletes_the_queue_and_stops_writing() {
    let dead = "http://127.0.0.1:9/batch/".to_owned();
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("optchat");
    let trace = Trace::open(&root.join("traces"), false).unwrap();
    // The worker re-reads consent on every wake, so the test's choice is a
    // switch both read.
    let on = Arc::new(AtomicBool::new(true));
    let analytics = Analytics::open(&root, config(dead), switch(&on)).unwrap();
    trace.set_analytics(analytics.clone());
    assert!(root.join("analytics/queue.jsonl").exists());
    on.store(false, Ordering::SeqCst);
    analytics.apply_consent(Consent::Off("test"));
    assert!(!root.join("analytics/queue.jsonl").exists());
    trace.emit("turn.end", json!({"status": "ok", "ms": 1}));
    assert!(
        !root.join("analytics/queue.jsonl").exists(),
        "nothing is written while off"
    );
    assert_eq!(analytics.flush().unwrap(), 0);
}

#[test]
fn a_host_that_starts_with_telemetry_off_writes_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("optchat");
    let on = Arc::new(AtomicBool::new(false));
    let analytics = Analytics::open(
        &root,
        config("http://127.0.0.1:9/batch/".into()),
        switch(&on),
    )
    .unwrap();
    assert!(!analytics.is_on());
    assert!(
        !root.join("analytics").exists(),
        "no directory, id or state for a host that never sends"
    );
    // Turning it on later starts sending, with a new install id.
    on.store(true, Ordering::SeqCst);
    analytics.apply_consent(Consent::Send("dev"));
    assert!(analytics.is_on());
    assert!(root.join("analytics/id").exists());
    let queue = std::fs::read_to_string(root.join("analytics/queue.jsonl")).unwrap();
    assert!(queue.contains("chief_host_started"));
}

#[test]
fn the_usage_rollup_goes_once_the_day_is_over() {
    let (url, rx) = server(200);
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("optchat");
    let analytics = Analytics::open(&root, config(url), || Consent::Send("dev")).unwrap();
    let day = 1_800_000_000_000u64;
    let line = |ts: u64, kind: &str, usd: f64| optchat_chief::usage::Line {
        ts,
        kind: kind.into(),
        input: 10,
        output: 5,
        cache_read: 85,
        usd: Some(usd),
        ..Default::default()
    };
    analytics.observe_unit(&line(day, "turn", 0.10));
    analytics.observe_unit(&line(day + 1, "compactor", 0.02));
    analytics.observe_unit(&line(day + 2, "subagent", 0.30));
    analytics.observe_unit(&line(day + 86_400_000, "turn", 0.01));
    analytics.flush().unwrap();
    let mut rollups = Vec::new();
    while let Ok(body) = rx.recv_timeout(Duration::from_secs(5)) {
        for e in body["batch"].as_array().unwrap() {
            if e["event"] == "chief_usage_daily" {
                rollups.push(e["properties"].clone());
            }
        }
        if !rollups.is_empty() {
            break;
        }
    }
    let r = &rollups[0];
    assert_eq!(r["day"], catalog::utc_day(day));
    assert_eq!(
        (
            r["turns"].clone(),
            r["compactor_nodes"].clone(),
            r["subagent_prompts"].clone()
        ),
        (json!(1), json!(1), json!(1))
    );
    assert_eq!(r["cost_usd"], 0.42);
    assert_eq!(r["cache_hit_rate"], 0.895);
}

#[test]
fn catalog_is_pinned() {
    // Renaming an event or a milestone changes the dashboards
    // (cmuxterm-hq scripts/posthog-chief-dashboard.py) and the doc.
    let doc = std::fs::read_to_string(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../docs/posthog/chief-product-analytics.md"
    ))
    .unwrap();
    for name in catalog::EVENTS.iter().chain(catalog::MILESTONES.iter()) {
        assert!(
            doc.contains(&format!("`{name}`")),
            "docs/posthog/chief-product-analytics.md does not name `{name}`"
        );
    }
}

/// The Chief answers with its `send` tool and ends its own turn (`stopped`,
/// `reply: null`): every real turn on 2026-11-15 looked like that, and none
/// counted as active or replied.
#[test]
fn a_turn_the_chief_ends_after_send_is_active_and_replied() {
    let mut state = State {
        installed_ms: 1_800_000_000_000,
        ..State::default()
    };
    let turn = "turn:optchat:1:1";
    let ts = 1_800_000_001_000;
    let send =
        json!({"ev": "tool", "turn": turn, "name": "mcp__optchat__send", "ok": true, "ts": ts});
    let end = json!({"ev": "turn.end", "turn": turn, "status": "stopped", "reply": null, "ts": ts});
    catalog::map(&send, &mut state, ts);
    let out = catalog::map(&end, &mut state, ts);
    let names: Vec<_> = out.iter().map(|e| e.name).collect();
    assert!(names.contains(&"chief_daily_active"), "{names:?}");
    let done = out
        .iter()
        .find(|e| e.name == "chief_turn_completed")
        .unwrap();
    assert_eq!(done.properties["turn_status"], json!("stopped"));
    assert_eq!(done.properties["replied"], json!(true));
    assert!(
        out.iter()
            .any(|e| e.properties.get("milestone") == Some(&json!("first_reply")))
    );

    // A side chat's turn that overlaps keeps its own mark.
    let side = "turn:optchat:2:1";
    let side_send = json!({"ev": "tool", "turn": side, "name": "mcp__optchat__send", "ok": true});
    let side_end = json!({"ev": "turn.end", "turn": side, "status": "stopped", "reply": null});
    catalog::map(&side_send, &mut state, ts);
    catalog::map(&send, &mut state, ts);
    let out = catalog::map(&side_end, &mut state, ts);
    let done = out
        .iter()
        .find(|e| e.name == "chief_turn_completed")
        .unwrap();
    assert_eq!(done.properties["replied"], json!(true));

    // A refused send, or a send in another turn, is no reply.
    let mut state = State::default();
    let refused = json!({"ev": "tool", "turn": turn, "name": "mcp__optchat__send", "ok": false});
    catalog::map(&refused, &mut state, ts);
    let out = catalog::map(&end, &mut state, ts);
    assert!(out.iter().all(|e| e.name != "chief_daily_active"));
    let other =
        json!({"ev": "tool", "turn": "turn:optchat:1:0", "name": "mcp__optchat__send", "ok": true});
    catalog::map(&other, &mut state, ts);
    let out = catalog::map(&end, &mut state, ts);
    assert!(out.iter().all(|e| e.name != "chief_daily_active"));
}

/// A failing compactor loop sends a sample per hour, not every failure.
#[test]
fn repeated_failures_are_capped_per_hour_with_a_count() {
    let mut state = State::default();
    let fail = json!({"ev": "node", "ok": false, "harness": "claude"});
    let hour = 1_800_000_000_000 / 3_600_000 * 3_600_000;
    let sent: usize = (0..500)
        .map(|i| catalog::map(&fail, &mut state, hour + i).len())
        .sum();
    assert_eq!(sent, catalog::BURST_PER_HOUR as usize);
    // Another reason has its own cap.
    let cap = json!({"ev": "compactor.capacity", "route": "claude", "status": 429});
    assert_eq!(catalog::map(&cap, &mut state, hour + 1).len(), 1);
    // The next hour sends again and says how many were held back.
    let next = catalog::map(&fail, &mut state, hour + 3_600_000);
    assert_eq!(next.len(), 1);
    assert_eq!(next[0].properties["repeats_dropped"], json!(490));
    // The cap is not saved: state.json does not change per failure.
    assert_eq!(
        serde_json::to_value(&state).unwrap(),
        serde_json::to_value(State::default()).unwrap()
    );
}
