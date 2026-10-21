//! Sign-ins down to one touch (Lawrence 2026-10-20): "1. The ACP subagent
//! escalates to you. 2. You will operate the browser on the right ... 3. You
//! trigger the passkey thing. 4. I can just scan my finger." A subagent has
//! an `escalate_auth` tool (MCP and launcher), and every Chief and subagent
//! prompt carries the flow by default, not one Chief's profile.

use optchat_chief::mcp::tools_for;
use optchat_chief::prompt::{Tools, chief_system_text, subagent_system_text};
use optchat_chief::tools::{Call, Command, command};
use serde_json::json;

fn names(list: &serde_json::Value) -> Vec<String> {
    list.as_array()
        .unwrap()
        .iter()
        .map(|t| t["name"].as_str().unwrap().to_owned())
        .collect()
}

fn flat(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

#[test]
fn a_subagent_lists_escalate_auth_and_the_chief_does_not() {
    let sub = tools_for(true);
    assert!(names(&sub).contains(&"escalate_auth".to_owned()), "{sub}");
    let tool = sub
        .as_array()
        .unwrap()
        .iter()
        .find(|t| t["name"] == "escalate_auth")
        .unwrap();
    assert_eq!(
        tool["inputSchema"]["required"],
        json!(["site", "url", "reason", "kind"])
    );
    assert!(!names(&tools_for(false)).contains(&"escalate_auth".to_owned()));
}

#[test]
fn escalate_auth_takes_four_kinds_and_an_http_page() {
    let call = |kind: &str, url: &str| {
        Call::parse(
            "escalate_auth",
            &json!({"site": "npmjs.com", "url": url, "reason": "add a trusted publisher", "kind": kind}),
        )
    };
    for kind in ["password", "passkey", "2fa", "oauth", "2FA"] {
        assert!(
            call(kind, "https://www.npmjs.com/login").is_ok(),
            "{kind}: {:?}",
            call(kind, "https://www.npmjs.com/login")
        );
    }
    assert!(call("sms", "https://www.npmjs.com/login").is_err());
    assert!(call("2fa", "javascript:alert(1)").is_err());
    assert!(
        Call::parse(
            "escalate_auth",
            &json!({"site": "npmjs.com", "kind": "2fa"})
        )
        .is_err(),
        "url and reason are required"
    );
}

#[test]
fn the_launcher_form_is_kind_site_url_then_the_reason() {
    let got = command(
        "escalate-auth",
        &[
            "2fa",
            "npmjs.com",
            "https://www.npmjs.com/login",
            "add",
            "a",
            "publisher",
        ],
    )
    .unwrap();
    let Command::Call(call) = got else {
        panic!("not a call: {got:?}")
    };
    assert_eq!(
        call,
        Call::parse(
            "escalate_auth",
            &json!({"site": "npmjs.com", "url": "https://www.npmjs.com/login", "reason": "add a publisher", "kind": "2fa"})
        )
        .unwrap()
    );
    assert!(matches!(
        command("escalate-auth", &["2fa"]).unwrap(),
        Command::Usage(_)
    ));
}

#[test]
fn every_chief_prompt_drives_sign_ins_down_to_one_touch() {
    let cli = Tools::Cli("/opt/chief".into());
    for (name, text) in [
        (
            "chief mcp",
            chief_system_text(None, &Tools::Mcp, false, false),
        ),
        ("chief cli", chief_system_text(None, &cli, true, true)),
    ] {
        let text = flat(&text);
        for needle in [
            "escalate_auth",
            "chief-auth-escalation",
            "Touch ID",
            "Needs you: touch the sensor",
            "never read or type a password",
            "~/.cmux/chief/skills/<name>/SKILL.md",
        ] {
            assert!(text.contains(needle), "{name}: no {needle:?}");
        }
        assert!(
            !text.contains("Sign-ins, payments and passwords stay with the user"),
            "{name}: the old hands-off rule is gone"
        );
    }
}

#[test]
fn every_subagent_prompt_escalates_instead_of_waiting_on_a_login_tab() {
    let mcp = flat(&subagent_system_text(None, &Tools::Mcp));
    let cli = flat(&subagent_system_text(
        None,
        &Tools::Cli("/opt/chief".into()),
    ));
    for (name, text) in [("mcp", &mcp), ("cli", &cli)] {
        assert!(
            text.contains("never wait on the tab for the user"),
            "{name}"
        );
        assert!(
            text.contains("escalate_auth(site, url, reason, kind)"),
            "{name}"
        );
    }
    assert!(
        cli.contains("/opt/chief escalate-auth KIND SITE URL"),
        "{cli}"
    );
}
