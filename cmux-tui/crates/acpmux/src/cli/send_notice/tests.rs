use super::*;

fn env<'a>(pairs: &'a [(&'a str, &'a str)]) -> impl Fn(&str) -> Option<String> + 'a {
    move |key| pairs.iter().find(|(k, _)| *k == key).map(|(_, v)| (*v).to_owned())
}

fn args(sender: Option<&str>, host: Option<&str>, links: &[&str]) -> SendNotice {
    SendNotice {
        notice: true,
        severity: Some("fire".into()),
        title: Some("fast tier failed on 3 PRs".into()),
        sender: sender.map(str::to_owned),
        host: host.map(str::to_owned),
        links: links.iter().map(|l| (*l).to_owned()).collect(),
    }
}

#[test]
fn the_sender_is_the_flag_else_from_else_acpmux_from_else_the_sessions_name() {
    let all = [("ACPMUX_FROM", "env-from"), ("ACPMUX_SESSION_NAME", "lane-1")];
    assert_eq!(default_sender(Some("cli-from"), env(&all)).as_deref(), Some("cli-from"));
    assert_eq!(default_sender(None, env(&all)).as_deref(), Some("env-from"));
    let session = [("ACPMUX_SESSION_NAME", "lane-1")];
    assert_eq!(default_sender(None, env(&session)).as_deref(), Some("lane-1"));
    assert_eq!(default_sender(Some("  "), env(&[])), None);
    let given = of_args(args(Some("base-red-watch"), Some("m-3"), &[]), Some("x"), env(&all));
    assert_eq!(given.unwrap().unwrap().sender(), "base-red-watch");
    let named = of_args(args(None, Some("m-3"), &[]), None, env(&session)).unwrap().unwrap();
    assert_eq!(named.sender(), "lane-1");
    assert!(of_args(args(None, Some("m-3"), &[]), None, env(&[])).is_err(), "no sender");
}

#[test]
fn no_notice_flag_is_no_notice_and_bad_fields_are_usage_errors() {
    assert_eq!(of_args(SendNotice::default(), Some("x"), env(&[])).unwrap(), None);
    let bad_link = of_args(args(Some("s"), Some("m"), &["http://x.dev"]), None, env(&[]));
    let message = bad_link.unwrap_err().to_string();
    assert!(message.contains("links.url"), "{message}");
    let bad_host = of_args(args(Some("s"), Some("a b"), &[]), None, env(&[]));
    assert!(bad_host.is_err());
}

#[test]
fn the_cli_renders_the_text_the_model_and_old_pages_read() {
    let notice = of_args(
        args(Some("base-red-watch"), Some("ci-mini-3"), &["https://github.com/o/r/pull/7=#7"]),
        None,
        env(&[]),
    )
    .unwrap()
    .unwrap();
    assert_eq!(
        notice.0,
        json!({"sender": "base-red-watch", "host": "ci-mini-3", "severity": "fire",
                   "title": "fast tier failed on 3 PRs",
                   "links": [{"url": "https://github.com/o/r/pull/7", "label": "#7"}]})
    );
    assert_eq!(
        text(Some(&notice), "red on #7"),
        "[notice from base-red-watch on ci-mini-3 · FIRE] fast tier failed on 3 PRs\n\
             red on #7\nLinks: https://github.com/o/r/pull/7 (#7)"
    );
    assert_eq!(text(None, "plain"), "plain");
    // No --host: this machine, when its name reads as one.
    let here = of_args(args(Some("s"), None, &[]), None, env(&[])).unwrap().unwrap();
    let host = here.0.get("host").and_then(Value::as_str);
    assert!(host.is_none_or(|h| !h.is_empty() && !h.ends_with(".local")), "{here:?}");
}
