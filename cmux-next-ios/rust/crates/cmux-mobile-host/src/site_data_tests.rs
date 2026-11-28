use serde_json::json;

use super::*;

const NOW: i64 = 1_800_000_000_000;

fn ask() -> Ask {
    parse_ask(&json!({"surface": 7, "url": "https://app.example.co.uk/inbox", "trigger": TRIGGER})).unwrap()
}

fn cookie(name: &str, domain: &str, expires_ms: Option<i64>) -> Cookie {
    Cookie {
        name: name.into(),
        value: format!("secret-{name}"),
        domain: domain.into(),
        path: "/".into(),
        expires_ms,
        secure: true,
        http_only: true,
        same_site: Some("lax".into()),
    }
}

fn tabs(surface: u64, kind: &str, url: &str) -> Value {
    json!({"id": "cmux-mobile-site-data", "data": {"workspaces": [{"screens": [{"panes": [{"tabs": [
        {"surface": 1, "kind": "terminal"},
        {"surface": surface, "kind": kind, "url": url},
    ]}]}]}]}})
}

#[test]
fn only_the_persons_open_on_iphone_asks() {
    for args in [
        json!({"surface": 7, "url": "https://example.com/"}),
        json!({"surface": 7, "url": "https://example.com/", "trigger": "agent"}),
        json!({"surface": 7, "url": "https://example.com/", "trigger": ""}),
    ] {
        assert_eq!(parse_ask(&args).unwrap_err().code, "no_person_action", "{args}");
    }
    assert_eq!(
        ask(),
        Ask { surface: 7, url: "https://app.example.co.uk/inbox".into(), site: "example.co.uk".into() }
    );
}

#[test]
fn only_web_pages_have_site_data() {
    for url in ["file:///etc/passwd", "about:blank", "cmux://settings", "not a url", "data:text/html,hi"] {
        let args = json!({"surface": 7, "url": url, "trigger": TRIGGER});
        assert_eq!(parse_ask(&args).unwrap_err().code, "bad_request", "{url}");
    }
    assert_eq!(
        parse_ask(&json!({"url": "https://a.com/", "trigger": TRIGGER})).unwrap_err().code,
        "bad_request"
    );
}

#[test]
fn the_tab_is_named_by_number_or_by_its_key() {
    for surface in [json!(7), json!("7"), json!("s7")] {
        let args = json!({"surface": surface, "url": "https://a.com/", "trigger": TRIGGER});
        assert_eq!(parse_ask(&args).unwrap().surface, 7, "{args}");
    }
    for surface in [json!("sx"), json!(-1), json!(null)] {
        let args = json!({"surface": surface, "url": "https://a.com/", "trigger": TRIGGER});
        assert_eq!(parse_ask(&args).unwrap_err().code, "bad_request", "{args}");
    }
}

#[test]
fn site_is_the_registrable_domain() {
    assert_eq!(site_of("mail.google.com"), "google.com");
    assert_eq!(site_of("GOOGLE.com."), "google.com");
    assert_eq!(site_of("a.b.example.co.uk"), "example.co.uk");
    assert_eq!(site_of("me.github.io"), "me.github.io");
    assert_eq!(site_of("localhost"), "localhost");
    assert_eq!(site_of("192.168.1.20"), "192.168.1.20");
    assert_eq!(web_site("http://localhost:3000/x").as_deref(), Some("localhost"));
    assert_eq!(web_site("http://[::1]:8080/").as_deref(), Some("[::1]"));
}

#[test]
fn on_site_is_the_site_or_below_it() {
    assert!(on_site(".example.co.uk", "example.co.uk"));
    assert!(on_site("app.example.co.uk", "example.co.uk"));
    assert!(!on_site("badexample.co.uk", "example.co.uk"));
    assert!(!on_site("co.uk", "example.co.uk"));
    assert!(!on_site("", "example.co.uk"));
}

#[test]
fn the_tab_must_be_a_listed_browser_tab_on_that_site() {
    let ask = ask();
    assert!(check_tab(&tabs(7, "browser", "https://www.example.co.uk/"), &ask).is_ok());
    // Navigated away since the phone asked.
    assert_eq!(check_tab(&tabs(7, "browser", "https://evil.com/"), &ask).unwrap_err().code, "forbidden");
    // Not a browser tab, or not listed (an incognito workspace is hidden from a remote client).
    assert_eq!(
        check_tab(&tabs(7, "terminal", "https://www.example.co.uk/"), &ask).unwrap_err().code,
        "forbidden"
    );
    assert_eq!(
        check_tab(&tabs(8, "browser", "https://www.example.co.uk/"), &ask).unwrap_err().code,
        "forbidden"
    );
    assert_eq!(check_tab(&json!({"data": {}}), &ask).unwrap_err().code, "forbidden");
}

#[test]
fn the_tabs_query_says_remote_so_incognito_stays_hidden() {
    let query = tabs_query();
    let hello: Value = serde_json::from_str(query.lines().next().unwrap()).unwrap();
    assert_eq!(hello["cmd"], "set-client-info");
    assert_eq!(hello["remote"], true);
    let list: Value = serde_json::from_str(query.lines().nth(1).unwrap()).unwrap();
    assert_eq!(list["cmd"], "list-workspaces");
    assert_eq!(list["id"], "cmux-mobile-site-data");
}

#[test]
fn only_the_sites_cookies_go_and_none_outlives_a_day() {
    let from_app = FromApp {
        profile_id: "default".into(),
        cookies: vec![
            cookie("sid", ".example.co.uk", Some(NOW + 30 * MAX_LIFETIME_MS)),
            cookie("pref", "app.example.co.uk", Some(NOW + 60_000)),
            cookie("session", "example.co.uk", None),
            cookie("old", "example.co.uk", Some(NOW - 1)),
            cookie("other", ".google.com", Some(NOW + 60_000)),
            cookie("suffix", ".co.uk", None),
            cookie("look_alike", "notexample.co.uk", None),
        ],
        local_storage: vec![
            StorageArea { origin: "https://app.example.co.uk".into(), items: vec![("k".into(), "v".into())] },
            StorageArea { origin: "https://evil.com".into(), items: vec![("k".into(), "v".into())] },
            StorageArea { origin: "file://".into(), items: vec![("k".into(), "v".into())] },
        ],
        ..FromApp::default()
    };
    let package = package(&ask(), from_app, NOW).unwrap();
    let names: Vec<&str> = package.cookies.iter().map(|c| c.name.as_str()).collect();
    assert_eq!(names, ["sid", "pref", "session"]);
    assert_eq!(package.cookies[0].expires_ms, Some(NOW + MAX_LIFETIME_MS), "capped at 24 h");
    assert_eq!(package.cookies[1].expires_ms, Some(NOW + 60_000), "its own sooner expiry kept");
    assert_eq!(package.cookies[2].expires_ms, None, "a session cookie stays one");
    assert_eq!(package.local_storage.len(), 1);
    assert_eq!(package.local_storage[0].origin, "https://app.example.co.uk");
    assert_eq!((package.v, package.site.as_str(), package.handed_at_ms), (1, "example.co.uk", NOW));
}

#[test]
fn incognito_and_the_agents_profile_never_leave_the_mac() {
    let with = |f: fn(&mut FromApp)| {
        let mut from_app =
            FromApp { cookies: vec![cookie("sid", "example.co.uk", None)], ..FromApp::default() };
        f(&mut from_app);
        package(&ask(), from_app, NOW).map(|_| ()).map_err(|e| e.code)
    };
    assert_eq!(with(|a| a.incognito = true), Err("forbidden"));
    assert_eq!(with(|a| a.agents_profile = true), Err("forbidden"));
    assert_eq!(with(|a| a.profile_id = "agent".into()), Err("forbidden"));
    assert_eq!(with(|a| a.profile_id = "Agents".into()), Err("forbidden"));
    assert_eq!(with(|a| a.profile_id = "work".into()), Ok(()));
}

#[test]
fn a_hand_off_is_bounded() {
    let many = FromApp {
        cookies: (0..=MAX_COOKIES).map(|i| cookie(&format!("c{i}"), "example.co.uk", None)).collect(),
        ..FromApp::default()
    };
    assert_eq!(package(&ask(), many, NOW).unwrap_err().code, "too_large");
    let big = FromApp {
        local_storage: vec![StorageArea {
            origin: "https://example.co.uk".into(),
            items: vec![("k".into(), "v".repeat(MAX_BYTES + 1))],
        }],
        ..FromApp::default()
    };
    assert_eq!(package(&ask(), big, NOW).unwrap_err().code, "too_large");
}

#[test]
fn values_never_reach_a_log() {
    let shown = format!("{:?}", cookie("sid", "example.co.uk", None));
    assert!(!shown.contains("secret-sid"), "{shown}");
    let area = StorageArea {
        origin: "https://example.co.uk".into(),
        items: vec![("token".into(), "s3cret".into())],
    };
    assert!(!format!("{area:?}").contains("s3cret"));
}

#[test]
fn the_apps_answer_parses_with_defaults() {
    let data: FromApp = serde_json::from_value(json!({
        "profile_id": "default",
        "cookies": [{"name": "sid", "value": "v", "domain": ".example.com"}],
        "local_storage": [{"origin": "https://example.com", "items": [["k", "v"]]}],
    }))
    .unwrap();
    assert_eq!(data.cookies[0].path, "/");
    assert_eq!(data.cookies[0].expires_ms, None);
    assert!(!data.incognito && !data.agents_profile);
    assert_eq!(data.local_storage[0].items, vec![("k".to_owned(), "v".to_owned())]);
}

#[tokio::test]
async fn the_app_is_asked_and_its_answer_or_failure_returns() {
    let ask = ask();
    let emitted = std::sync::Mutex::new(Vec::new());
    let emit = |event: &crate::control::Event| {
        emitted.lock().unwrap().push(event.clone());
        if let crate::control::Event::NeedSiteData { request, surface, site, .. } = event {
            assert_eq!((*surface, site.as_str()), (7, "example.co.uk"));
            answer(*request, Ok(FromApp { profile_id: "default".into(), ..FromApp::default() }));
        }
    };
    assert_eq!(ask_app(&ask, &emit).await.unwrap().profile_id, "default");
    let fail = |event: &crate::control::Event| {
        if let crate::control::Event::NeedSiteData { request, .. } = event {
            answer(*request, Err("store locked".into()));
        }
    };
    let refused = ask_app(&ask, &fail).await.unwrap_err();
    assert_eq!((refused.code, refused.reason.as_str()), ("unavailable", "store locked"));
    let line = serde_json::to_value(&emitted.lock().unwrap()[0]).unwrap();
    assert_eq!(line["type"], "need_site_data");
    assert_eq!(line["url"], "https://app.example.co.uk/inbox");
}

#[test]
fn the_app_lines_parse() {
    use crate::control::Inbound;
    assert_eq!(
        Inbound::parse(r#"{"type":"site_data_handoff","enabled":true}"#),
        Some(Inbound::SiteDataHandoff { enabled: true })
    );
    assert_eq!(
        Inbound::parse(r#"{"type":"site_data_failed","request":3,"reason":"no tab"}"#),
        Some(Inbound::SiteDataFailed { request: 3, reason: "no tab".into() })
    );
    let Some(Inbound::SiteData { request, data }) =
        Inbound::parse(r#"{"type":"site_data","request":4,"data":{"incognito":true,"cookies":[]}}"#)
    else {
        panic!("site_data did not parse");
    };
    assert_eq!(request, 4);
    assert!(data.incognito);
}

#[test]
fn off_by_default() {
    // No other test turns it on: the default before the app's line is off.
    assert!(!enabled());
}
