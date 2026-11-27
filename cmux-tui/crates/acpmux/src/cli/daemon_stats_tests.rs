use super::*;
use crate::caller_stats::{Caller, CallerStats};

fn report() -> Value {
    let stats = CallerStats::new();
    let busy = Caller {
        client: "cmux-next-turn-states".to_owned(),
        origin: "local",
        pid: Some(4242),
        session: Some("s-busy".to_owned()),
        proven: false,
    };
    let pane =
        Caller { client: String::new(), origin: "app", pid: None, session: None, proven: false };
    for _ in 0..650 {
        stats.observe_request_at(&busy, "_acpmux/sessions", 80, 30);
        stats.observe_reply_at(&busy, "_acpmux/sessions", 2 << 20, 30);
    }
    stats.observe_request_at(&busy, "initialize", 300, 30);
    stats.observe_request_at(&pane, "_acpmux/status", 40, 31);
    stats.report_at(40, 60, 20)
}

#[test]
fn by_caller_names_the_busiest_client_with_its_pid_session_and_methods() {
    let text = render(&report(), By::Caller);
    let lines: Vec<&str> = text.lines().collect();
    assert!(lines[0].starts_with("last 60s: 2 callers (2 shown)"), "{text}");
    assert!(lines[1].contains("REQ/MIN") && lines[1].contains("PID"), "{text}");
    let busy = lines[2];
    assert!(busy.contains("651.0"), "{busy}");
    assert!(busy.contains("4242"), "{busy}");
    assert!(busy.contains("cmux-next-turn-states"), "{busy}");
    assert!(busy.contains("s-busy?"), "an unproven session is marked: {busy}");
    assert!(busy.contains("1.3 GB"), "{busy}");
    assert!(busy.contains("_acpmux/sessions x650, initialize x1"), "{busy}");
    let pane = lines[3];
    assert!(pane.contains("(unnamed)") && pane.contains("app"), "{pane}");
}

#[test]
fn by_method_counts_each_methods_callers() {
    let text = render(&report(), By::Method);
    assert!(text.lines().next().is_some_and(|l| l.contains("3 methods")), "{text}");
    let sessions = text.lines().find(|l| l.ends_with("_acpmux/sessions")).unwrap();
    assert!(sessions.contains("650") && sessions.contains("1.3 GB"), "{sessions}");
}

#[test]
fn an_empty_window_says_so() {
    let text = render(&CallerStats::new().report_at(5, 60, 20), By::Caller);
    assert!(text.contains("no requests in the window"), "{text}");
}

#[test]
fn an_older_daemon_shows_its_list_replies_most_first() {
    let list = json!({
        "quiet (Local)": {"replies": 2, "bytes": 100, "largest": 60},
        "busy (LocalApp)": {"replies": 650, "bytes": 31u64 << 20, "largest": 1 << 20},
    });
    let text = render_list_replies(&list, 20);
    let lines: Vec<&str> = text.lines().collect();
    assert!(lines[0].contains("no per-caller stats"), "{text}");
    assert!(lines[2].ends_with("busy (LocalApp)") && lines[2].contains("31.0 MB"), "{text}");
    assert!(lines[3].ends_with("quiet (Local)"), "{text}");
    assert_eq!(render_list_replies(&list, 1).lines().count(), 3);
}

#[test]
fn bytes_read_as_units() {
    assert_eq!(human(512), "512 B");
    assert_eq!(human(1536), "1.5 KB");
    assert_eq!(human(31 << 20), "31.0 MB");
}
