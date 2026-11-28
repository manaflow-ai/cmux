//! A chat share link is read as the Mac daemon reads it (`agent_session_share_link.rs`), split as
//! Foundation's URLComponents splits it, and the page the phone opens carries `in_app=1`, the
//! one-time hand-off code and the guest secret. Mirrors ChatShareLinkTests.swift and the share
//! cases of OpenedURLTests.swift.

use super::*;

const ID: &str = "0123456789abcdefABCD";

fn parsed(text: &str) -> Option<ParsedChatShareLink> {
    chat_share_link_parse(text.to_owned())
}

fn link(page: ChatSharePage, secret: Option<&str>) -> ParsedChatShareLink {
    ParsedChatShareLink {
        origin: "https://share.cmux.dev".into(),
        page,
        share_id: ID.into(),
        secret: secret.map(str::to_owned),
    }
}

#[test]
fn a_guest_link_keeps_its_secret_and_an_invite_has_none() {
    assert_eq!(
        parsed(&format!("https://share.cmux.dev/g/{ID}/#abcdefgh")),
        Some(link(ChatSharePage::Guest, Some("abcdefgh")))
    );
    assert_eq!(
        parsed(&format!("https://SHARE.cmux.dev/i/{ID}#ignored1")),
        Some(link(ChatSharePage::Invite, None))
    );
    // Links made before the share host still open; they move to it.
    let old = parsed(&format!("https://cmux-platform-production.debussy.workers.dev/i/{ID}")).unwrap();
    assert_eq!(old.origin, "https://cmux-platform-production.debussy.workers.dev");
    assert!(parsed(&format!("https://cmux-platform-staging.debussy.workers.dev/g/{ID}")).is_some());
}

#[test]
fn only_the_share_hosts_well_formed_pages_are_links() {
    for text in [
        format!("http://share.cmux.dev/g/{ID}#abcdefgh"),
        format!("https://share.cmux.dev:8443/g/{ID}#abcdefgh"),
        // A written default port is a port too (the url crate would drop it).
        format!("https://share.cmux.dev:443/g/{ID}#abcdefgh"),
        format!("https://user@share.cmux.dev/g/{ID}#abcdefgh"),
        format!("https://user:pw@share.cmux.dev/g/{ID}#abcdefgh"),
        format!("https://@share.cmux.dev/g/{ID}#abcdefgh"),
        format!("https://share.cmux.dev.evil.example/g/{ID}"),
        format!("https://share.cmux.dev/g/{ID}/extra"),
        format!("https://share.cmux.dev/g/{ID}#short"),
        "https://share.cmux.dev/g/has%20space0123456789".into(),
        format!("cmux://share?link=https%3A%2F%2Fevil.example%2Fg%2F{ID}#abcdefgh"),
        format!("https://cmux.com/g/{ID}"),
        format!("https://evil.example/g/{ID}#s3cret-_x"),
        format!("https://share.cmux.dev/x/{ID}"),
        "https://share.cmux.dev/g/short".into(),
        // No path normalization: dot segments are segments (the url crate would resolve them).
        format!("https://share.cmux.dev/x/../g/{ID}"),
        format!("https://share.cmux.dev/./g/{ID}"),
        format!("https://share.cmux.dev//g/{ID}"),
        format!("https://share.cmux.dev/g/{ID}//"),
        "not a url".into(),
        format!("share.cmux.dev/g/{ID}"),
    ] {
        assert_eq!(parsed(&text), None, "{text}");
    }
}

#[test]
fn the_path_and_fragment_are_read_decoded() {
    // URLComponents' path and fragment are percent-decoded.
    assert_eq!(
        parsed(&format!("https://share.cmux.dev/%67/{ID}#abc%64efgh")),
        Some(link(ChatSharePage::Guest, Some("abcdefgh")))
    );
    // A decoded slash splits the path, as URLComponents' decoded path does.
    assert_eq!(
        parsed(&format!("https://share.cmux.dev/g/{ID}%2F#abcdefgh")),
        Some(link(ChatSharePage::Guest, Some("abcdefgh")))
    );
    // An empty fragment is no secret.
    assert_eq!(parsed(&format!("https://share.cmux.dev/g/{ID}#")), Some(link(ChatSharePage::Guest, None)));
    // A secret past 128 characters or with another character is malformed.
    assert_eq!(parsed(&format!("https://share.cmux.dev/g/{ID}#{}", "a".repeat(129))), None);
    assert_eq!(parsed(&format!("https://share.cmux.dev/g/{ID}#abcd.efgh")), None);
}

#[test]
fn the_guest_pages_open_in_app_link_carries_the_page() {
    let guest = Some(link(ChatSharePage::Guest, Some("s3cret-_x")));
    // `?app=<scheme>` is dropped; the outer fragment is the secret.
    assert_eq!(
        parsed(&format!("cmux://share?link=https%3A%2F%2Fshare.cmux.dev%2Fg%2F{ID}%3Fapp%3Dcmux#s3cret-_x")),
        guest
    );
    assert_eq!(
        parsed(&format!("cmux-dev-tag://SHARE/?link=https%3A%2F%2Fshare.cmux.dev%2Fg%2F{ID}#s3cret-_x")),
        guest
    );
    // The inner link's own fragment wins.
    assert_eq!(
        parsed(&format!("cmux://share?link=https%3A%2F%2Fshare.cmux.dev%2Fg%2F{ID}%23s3cret-_x#otherone")),
        guest
    );
    for text in [
        // Not a cmux build's scheme.
        format!("cmux-next://share?link=https%3A%2F%2Fshare.cmux.dev%2Fg%2F{ID}#s3cret-_x"),
        // Another host or a path.
        format!("cmux://open?link=https%3A%2F%2Fshare.cmux.dev%2Fg%2F{ID}#s3cret-_x"),
        format!("cmux://share/x?link=https%3A%2F%2Fshare.cmux.dev%2Fg%2F{ID}#s3cret-_x"),
        // No link, two, or one with no value.
        "cmux://share?x=1#s3cret-_x".into(),
        format!(
            "cmux://share?link=https%3A%2F%2Fshare.cmux.dev%2Fg%2F{ID}&link=https%3A%2F%2Fshare.cmux.dev%2Fg%2F{ID}"
        ),
        "cmux://share?link".into(),
        // The inner link is http, or no URL.
        format!("cmux://share?link=http%3A%2F%2Fshare.cmux.dev%2Fg%2F{ID}#s3cret-_x"),
        format!("cmux://share?link=https%3A%2F%2Fshare.cmux.dev%2Fg%2F{ID}%20x#s3cret-_x"),
        // A user on the outer link.
        format!("cmux://u@share?link=https%3A%2F%2Fshare.cmux.dev%2Fg%2F{ID}#s3cret-_x"),
    ] {
        assert_eq!(parsed(&text), None, "{text}");
    }
}

#[test]
fn a_link_is_made_only_from_a_well_formed_id_and_secret() {
    let make = |id: &str, secret: Option<&str>| {
        chat_share_link_make(
            "https://share.cmux.dev".into(),
            ChatSharePage::Guest,
            id.into(),
            secret.map(str::to_owned),
        )
    };
    assert_eq!(make(ID, Some("s3cret-_x")), Some(link(ChatSharePage::Guest, Some("s3cret-_x"))));
    assert_eq!(make(ID, None), Some(link(ChatSharePage::Guest, None)));
    assert_eq!(make("short", None), None);
    assert_eq!(make(&"a".repeat(129), None), None);
    assert_eq!(make(ID, Some("short")), None);
    assert!(chat_share_is_id("a".repeat(16)) && chat_share_is_id("a".repeat(128)));
    assert!(!chat_share_is_id("a".repeat(15)) && !chat_share_is_id(format!("{ID}é")));
}

#[test]
fn the_page_carries_the_hand_off_and_the_secret() {
    let guest = link(ChatSharePage::Guest, Some("abcdefgh"));
    assert_eq!(
        chat_share_handoff_url(guest.clone()),
        format!("https://share.cmux.dev/v1/chat-shares/{ID}/handoff")
    );
    let code = "HANDOFF_code-0123456789";
    assert_eq!(
        chat_share_page_url(guest.clone(), Some(code.into())),
        format!("https://share.cmux.dev/g/{ID}?in_app=1&cmux_handoff={code}#abcdefgh")
    );
    assert_eq!(
        chat_share_page_url(guest.clone(), None),
        format!("https://share.cmux.dev/g/{ID}?in_app=1#abcdefgh")
    );
    // A malformed code is dropped: the page opens signed out.
    assert_eq!(
        chat_share_page_url(guest, Some("bad code&x=1".into())),
        format!("https://share.cmux.dev/g/{ID}?in_app=1#abcdefgh")
    );
    assert_eq!(
        chat_share_page_url(link(ChatSharePage::Invite, None), None),
        format!("https://share.cmux.dev/i/{ID}?in_app=1")
    );
}
