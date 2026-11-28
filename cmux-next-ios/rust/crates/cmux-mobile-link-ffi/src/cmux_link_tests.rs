//! The phone reads the links the Mac writes (`CmuxNextActions/DeepLink`) and
//! the https forms cmux.com and the Cloud service hand out
//! (cmux-next-ios/verify/deep-links.md). Mirrors CmuxLinkTests.swift.

use super::*;

const WS: &str = "ws_0123456789abcdef0123456789abcdef";
const PANE: &str = "pane_0123456789abcdef0123456789abcdef";
const TAB: &str = "tab_0123456789abcdef0123456789abcdef";
const DEVICE: &str = "0f8e2c1a-3b4d-4e5f-8a9b-0c1d2e3f4a5b";
const GROUP: &str = "grp_abcdefghij0123456789";

fn target(text: &str) -> Option<CmuxLinkTarget> {
    parse(text).map(|l| l.target)
}

fn s(text: &str) -> String {
    text.to_owned()
}

fn screen(display: Option<&str>, control: bool, name: Option<&str>) -> Option<CmuxLinkTarget> {
    Some(CmuxLinkTarget::MacScreen { device: s(DEVICE), display: display.map(s), control, name: name.map(s) })
}

#[test]
fn reads_every_kind_the_mac_writes() {
    use CmuxLinkTarget::*;
    assert_eq!(target(&format!("cmux://workspace/{WS}")), Some(Workspace { id: s(WS) }));
    assert_eq!(target(&format!("cmux://pane/{PANE}")), Some(Pane { id: s(PANE) }));
    assert_eq!(
        target(&format!("cmux://tab/{TAB}?machine=machine_0123456789abcdef0123456789abcdef")),
        Some(Tab { id: s(TAB) })
    );
    assert_eq!(target("cmux://session/s-1#turn-t9"), Some(Session { id: s("s-1"), turn: Some(s("t9")) }));
    assert_eq!(target("cmux://session/s-1"), Some(Session { id: s("s-1"), turn: None }));
    assert_eq!(
        target("cmux://chief/0a1b2c3d/session/s-1"),
        Some(ChiefSession { home: s("0a1b2c3d"), session: s("s-1") })
    );
    assert_eq!(
        target(&format!("cmux://group/{GROUP}/workspace/{WS}")),
        Some(Group { id: s(GROUP), workspace: Some(s(WS)) })
    );
    assert_eq!(
        target("cmux://conversation/c-release/message/c-release-m4"),
        Some(Conversation { id: s("c-release"), message: Some(s("c-release-m4")) })
    );
}

/// A Mac screen link (`acpmux share-host link`): one shape, native and web; View Only unless `control=1`.
#[test]
fn reads_a_mac_screen_link() {
    let expected = screen(Some("69734272"), false, None);
    for scheme in ["cmux", "cmux-nightly", "cmux-dev-my-tag"] {
        assert_eq!(
            target(&format!("{scheme}://mac-screen?device={DEVICE}&display=69734272")),
            expected,
            "{scheme}"
        );
    }
    for host in ["cmux.com", "www.cmux.com"] {
        assert_eq!(
            target(&format!("https://{host}/deeplink/screen?device={DEVICE}&display=69734272")),
            expected,
            "{host}"
        );
    }
    assert_eq!(
        target(&format!("https://cmux.com/en/deeplink/screen?device={DEVICE}")),
        screen(None, false, None)
    );
    // Upper case ids read as the hub's lowercase one; control and the label ride along.
    assert_eq!(
        target(&format!("cmux://mac-screen?device={}&control=1&name=ui%20run%2042", DEVICE.to_uppercase())),
        screen(None, true, Some("ui run 42"))
    );
    assert_eq!(target(&format!("cmux://mac-screen?device={DEVICE}&control=0")), screen(None, false, None));
    assert_eq!(target(&format!("cmux://mac-screen?device={DEVICE}&name=%20%20")), screen(None, false, None));
    for text in [
        s("cmux://mac-screen"),
        s("cmux://mac-screen?device=not-a-uuid"),
        s("cmux://mac-screen?display=1"),
        format!("cmux://mac-screen?device={DEVICE}&display=-1"),
        format!("cmux://mac-screen?device={DEVICE}&display=4294967296"),
        format!("cmux://mac-screen?device={DEVICE}&display=1&display=2"),
        format!("cmux://mac-screen/x?device={DEVICE}"),
        format!("cmux://mac-screen?device={DEVICE}#x"),
        format!("https://example.com/deeplink/screen?device={DEVICE}"),
        format!("cmux-next://mac-screen?device={DEVICE}"),
    ] {
        assert_eq!(target(&text), None, "{text}");
    }
}

#[test]
fn reads_every_mac_builds_scheme() {
    for scheme in ["cmux", "CMUX", "cmux-nightly", "cmux-rc", "cmux-dev", "cmux-dev-my-tag"] {
        assert_eq!(
            target(&format!("{scheme}://tab/{TAB}")),
            Some(CmuxLinkTarget::Tab { id: s(TAB) }),
            "{scheme}"
        );
    }
    assert!(is_link_scheme("CMUX-DEV-x"));
    assert!(!is_link_scheme("cmux-next"));
}

#[test]
fn refuses_what_is_not_a_link() {
    for text in [
        s("cmux://auth-callback?code=x"),
        s("cmux-next://pair?mac=m&t=secret"),
        format!("other://tab/{TAB}"),
        s("cmux://tab/tab_ABC"),
        format!("cmux://tab/{TAB}/extra"),
        s("cmux://workspace/0F8E2C1A-3B4D-4E5F-8A9B-0C1D2E3F4A5B"),
        format!("cmux://tab/{TAB}#x"),
        format!("cmux://user:pw@tab/{TAB}"),
        format!("cmux://tab:1/{TAB}"),
        format!("https://cmux.com:443/link/tab/{TAB}"),
        format!("https://example.com/link/tab/{TAB}"),
        s("https://cmux.com/terms-of-service"),
        s("https://cmux.com/link/tab/nope"),
        s("cmux://session/s-1#other"),
        s("not a url"),
    ] {
        assert_eq!(target(&text), None, "{text}");
    }
}

#[test]
fn reads_the_https_forms() {
    use CmuxLinkTarget::*;
    assert_eq!(target(&format!("https://cmux.com/link/tab/{TAB}")), Some(Tab { id: s(TAB) }));
    assert_eq!(
        target(&format!("https://www.cmux.com/en/link/workspace/{WS}")),
        Some(Workspace { id: s(WS) })
    );
    assert_eq!(
        target(&format!("https://www.cmux.com/zh-CN/link/workspace/{WS}")),
        Some(Workspace { id: s(WS) })
    );
    assert_eq!(
        target(&format!("https://cloud-api.cmux.dev/g/{GROUP}")),
        Some(Group { id: s(GROUP), workspace: None })
    );
    assert_eq!(
        target(&format!("https://cloud-api-staging.cmux.dev/g/{GROUP}/w/{WS}")),
        Some(Group { id: s(GROUP), workspace: Some(s(WS)) })
    );
    assert_eq!(
        target("https://cmux.com/ja/deeplink/agent?harness=codex&session=s1"),
        Some(Agent { harness: s("codex"), session: s("s1") })
    );
    // A cloud host serves only the group page.
    assert_eq!(target(&format!("https://cloud-api.cmux.dev/link/tab/{TAB}")), None);
}

/// schemas/deeplinks/agent-link.json is the one contract the Mac, the CLI,
/// acpmux and cmux.com write agent links by: each of its vectors reads the same here.
#[test]
fn follows_the_shared_agent_link_schema() {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../../../schemas/deeplinks/agent-link.json");
    let text = std::fs::read_to_string(path).expect("agent-link.json");
    let schema: serde_json::Value = serde_json::from_str(&text).expect("schema json");
    let vectors = schema["vectors"].as_array().expect("vectors");
    assert!(vectors.len() > 10);
    for vector in vectors {
        let name = vector["name"].as_str().unwrap_or("?");
        let mut forms = Vec::new();
        if let Some(web) = vector["web"].as_str() {
            forms.push(format!("https://cmux.com/deeplink/agent?{web}"));
        } else if let Some(native) = vector["link"].as_str() {
            forms.push(native.to_owned());
        }
        for form in forms {
            let parsed = parse(&form);
            let fields = &vector["fields"];
            if fields.is_null() {
                assert_eq!(parsed, None, "{name}: {form}");
                continue;
            }
            let field = |key: &str| fields[key].as_str().map(str::to_owned);
            let parsed = parsed.unwrap_or_else(|| panic!("{name}: {form} did not parse"));
            assert_eq!(
                parsed.target,
                CmuxLinkTarget::Agent {
                    harness: field("harness").unwrap(),
                    session: field("session").unwrap()
                },
                "{name}: {form}"
            );
            assert_eq!(parsed.message, field("message"), "{name}: {form}");
        }
    }
}

#[test]
fn decodes_percent_escapes_as_foundation_does() {
    assert_eq!(decode("a%20b+c").as_deref(), Some("a b+c"));
    assert_eq!(decode("100%").as_deref(), Some("100%"));
    assert_eq!(decode("%zz").as_deref(), Some("%zz"));
    assert_eq!(decode("%ff"), None);
}
