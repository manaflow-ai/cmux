use super::*;
use crate::cli::machine_consent::for_account;
use ring::signature::{ECDSA_P256_SHA256_FIXED_SIGNING, EcdsaKeyPair, KeyPair};

const ACCOUNT_ID: &str = "user_abc";
const OTHER_ACCOUNT: &str = "user_other";
const MACHINE: &str = "machine_target";
const NOW: u64 = 1_794_781_755_488;

fn node_key(byte: u8) -> String {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD.encode([byte; 32])
}

fn key() -> EcdsaKeyPair {
    let rng = ring::rand::SystemRandom::new();
    let pkcs8 = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &rng).unwrap();
    EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, pkcs8.as_ref(), &rng).unwrap()
}

fn public(k: &EcdsaKeyPair) -> Vec<u8> {
    k.public_key().as_ref().to_vec()
}

fn fixture() -> (tempfile::TempDir, Authority) {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("os-account/.acpmux/machine-consent");
    let authority = Authority::at(root, dir.path().join("tag"));
    authority.enroll().unwrap();
    (dir, authority)
}

fn target_for(account: Option<&str>) -> Target {
    Target {
        account: account.map(str::to_owned),
        machine_id: Some(MACHINE.into()),
        node_key: Some(node_key(7)),
        name: Some("mini-7".into()),
    }
}

fn target() -> Target {
    target_for(Some(ACCOUNT_ID))
}

/// Signs `grant` (its signed fields as they are now) with `k`.
fn sign(k: &EcdsaKeyPair, grant: &mut Value) {
    let text = |field: &str| grant[field].as_str().unwrap_or_default().to_owned();
    let number = |field: &str| grant[field].as_u64().unwrap_or_default();
    let bytes = message(
        &text("grantor"),
        &text("account"),
        &text("machineId"),
        &text("nodeKey"),
        &text("control"),
        &text("screen"),
        number("issuedAt"),
        number("expiresAt"),
    );
    let rng = ring::rand::SystemRandom::new();
    grant["signature"] = json!(hex(k.sign(&rng, &bytes).unwrap().as_ref()));
}

/// A grant from `k` for this test's machine and account, `edit`ed, then signed by `k`.
fn grant(k: &EcdsaKeyPair, edit: impl FnOnce(&mut Value)) -> Value {
    let key = public(k);
    let mut grant = json!({
        "v": 1, "grantor": grantor_id(&key), "account": ACCOUNT_ID, "machineId": MACHINE,
        "nodeKey": node_key(7), "control": "on", "screen": "on",
        "issuedAt": NOW - 1_000, "expiresAt": NOW + 60_000,
        "publicKey": hex(&key), "name": "Leo's MacBook Pro",
    });
    edit(&mut grant);
    sign(k, &mut grant);
    grant
}

/// Pins `k` the one way there is: its first grant leaves an ask, which the person allows here.
fn pin(authority: &Authority, k: &EcdsaKeyPair, account: &str) {
    let first = grant(k, |g| g["account"] = json!(account));
    let refused = apply(authority, &first, &target_for(Some(account)), Some("mbp"), NOW);
    assert_eq!(refused.unwrap_err().reason, UNPINNED);
    let id = grantor_id(&public(k));
    trust(authority, &id, true, Some(account), NOW).unwrap();
}

fn status(authority: &Authority, account: Option<&str>) -> Value {
    for_account(authority.status(), account)
}

fn consent_of<'a>(status: &'a Value, surface: &str) -> &'a str {
    status["consent"][surface].as_str().unwrap_or_default()
}

fn log(authority: &Authority) -> Vec<Value> {
    log_lines(authority.root(), MAX_LOG_LINES)
}

#[test]
fn the_signed_bytes_are_the_contracts_test_vector() {
    let bytes =
        message("mac-0011223344556677", "user_abc", "m_1", "AAAA", "on", "keep", 1000, 2000);
    assert_eq!(
        bytes,
        b"acpmux-consent-grant-v1\x00mac-0011223344556677\x00user_abc\x00m_1\x00AAAA\x00on\x00keep\x001000\x002000"
            .to_vec()
    );
}

#[test]
fn a_grant_the_pinned_key_signed_for_this_machine_turns_control_and_screen_on() {
    let (_dir, authority) = fixture();
    let k = key();
    pin(&authority, &k, ACCOUNT_ID);
    let before = status(&authority, Some(ACCOUNT_ID));
    assert_eq!(consent_of(&before, "control"), "none");
    let consent = apply(&authority, &grant(&k, |_| {}), &target(), Some("mbp"), NOW).unwrap();
    assert!(consent.control_granted_by.is_some());
    let after = status(&authority, Some(ACCOUNT_ID));
    assert_eq!(consent_of(&after, "control"), "granted");
    assert_eq!(consent_of(&after, "screen"), "granted");
    let id = grantor_id(&public(&k));
    assert_eq!(after["consent"]["controlGrantedBy"]["grantor"], json!(id));
    assert_eq!(after["consent"]["controlGrantedBy"]["account"], json!(ACCOUNT_ID));
    let grants = log(&authority);
    let grants: Vec<&Value> = grants.iter().filter(|l| l["event"] == "grant").collect();
    assert_eq!(grants.len(), 2);
    assert_eq!(grants[0]["by"], json!(id));
    assert_eq!(grants[0]["from"], "mbp");
    assert_eq!(grants[0]["account"], ACCOUNT_ID);
}

#[test]
fn an_unpinned_grant_is_refused_and_leaves_one_ask_with_the_keys_words() {
    let (_dir, authority) = fixture();
    let k = key();
    let refused = apply(&authority, &grant(&k, |_| {}), &target(), Some("mbp"), NOW).unwrap_err();
    assert_eq!(refused.reason, UNPINNED);
    assert_eq!(refused.words, Some(words(&public(&k))));
    assert_eq!(refused.answer()["words"], json!(words(&public(&k))));
    let fields = status_fields(&authority, Some(ACCOUNT_ID));
    let ask = &fields["grantorAsk"];
    assert_eq!(ask["id"], json!(grantor_id(&public(&k))));
    assert_eq!(ask["from"], "mbp");
    assert_eq!(ask["words"], json!(words(&public(&k))));
    assert_eq!(consent_of(&status(&authority, Some(ACCOUNT_ID)), "control"), "none");
    let events: Vec<String> =
        log(&authority).iter().map(|l| l["event"].as_str().unwrap().to_owned()).collect();
    assert_eq!(events, ["ask", "refused"]);
    assert_eq!(log(&authority)[1]["reason"], UNPINNED);
    // An ask is for the account it was made for.
    assert!(status_fields(&authority, Some(OTHER_ACCOUNT))["grantorAsk"].is_null());
}

#[test]
fn each_check_refuses_with_its_reason_and_changes_nothing() {
    let (_dir, authority) = fixture();
    let k = key();
    pin(&authority, &k, ACCOUNT_ID);
    let cases: Vec<(&str, Value, Target)> = vec![
        ("account", grant(&k, |g| g["account"] = json!(OTHER_ACCOUNT)), target()),
        ("machine id", grant(&k, |g| g["machineId"] = json!("machine_other")), target()),
        ("node key", grant(&k, |g| g["nodeKey"] = json!(node_key(9))), target()),
        (
            "expired",
            grant(&k, |g| {
                g["issuedAt"] = json!(NOW - 2_000);
                g["expiresAt"] = json!(NOW - 1);
            }),
            target(),
        ),
        (
            "too long",
            grant(&k, |g| {
                g["issuedAt"] = json!(NOW - 1_000);
                g["expiresAt"] = json!(NOW - 1_000 + MAX_LIFETIME_MS + 1);
            }),
            target(),
        ),
        (
            "issued in the future",
            grant(&k, |g| {
                g["issuedAt"] = json!(NOW + 120_000);
                g["expiresAt"] = json!(NOW + 130_000);
            }),
            target(),
        ),
        ("not joined", grant(&k, |_| {}), target_for(None)),
        ("malformed", grant(&k, |g| g["control"] = json!("maybe")), target()),
        (
            "nothing to change",
            grant(&k, |g| {
                g["control"] = json!("keep");
                g["screen"] = json!("keep");
            }),
            target(),
        ),
        ("version", grant(&k, |g| g["v"] = json!(2)), target()),
        (
            "bad signature",
            {
                let mut g = grant(&k, |_| {});
                let mut signature = g["signature"].as_str().unwrap().to_owned();
                let flipped = if signature.starts_with('0') { "1" } else { "0" };
                signature.replace_range(0..1, flipped);
                g["signature"] = json!(signature);
                g
            },
            target(),
        ),
        (
            "altered after signing",
            {
                let mut g = grant(&k, |g| g["screen"] = json!("keep"));
                g["screen"] = json!("on");
                g
            },
            target(),
        ),
    ];
    let want = [
        ACCOUNT, TARGET, TARGET, EXPIRED, EXPIRED, EXPIRED, NOT_JOINED, MALFORMED, MALFORMED,
        MALFORMED, SIGNATURE, SIGNATURE,
    ];
    for ((name, value, target), want) in cases.into_iter().zip(want) {
        let refused = apply(&authority, &value, &target, None, NOW).unwrap_err();
        assert_eq!(refused.reason, want, "{name}");
        let now = status(&authority, Some(ACCOUNT_ID));
        assert_eq!(consent_of(&now, "control"), "none", "{name}");
        assert_eq!(consent_of(&now, "screen"), "none", "{name}");
    }
    let refused = log(&authority).iter().filter(|l| l["event"] == "refused").count();
    assert_eq!(refused, 13, "every refusal is logged (the pin's first grant too)");
}

#[test]
fn a_replayed_or_older_grant_is_refused() {
    let (_dir, authority) = fixture();
    let k = key();
    pin(&authority, &k, ACCOUNT_ID);
    let first = grant(&k, |_| {});
    apply(&authority, &first, &target(), None, NOW).unwrap();
    assert_eq!(apply(&authority, &first, &target(), None, NOW).unwrap_err().reason, REPLAYED);
    let older = grant(&k, |g| {
        g["issuedAt"] = json!(NOW - 1_001);
        g["control"] = json!("off");
    });
    assert_eq!(apply(&authority, &older, &target(), None, NOW).unwrap_err().reason, REPLAYED);
    assert_eq!(consent_of(&status(&authority, Some(ACCOUNT_ID)), "control"), "granted");
    let newer = grant(&k, |g| {
        g["issuedAt"] = json!(NOW - 999);
        g["control"] = json!("off");
    });
    apply(&authority, &newer, &target(), None, NOW).unwrap();
    assert_eq!(consent_of(&status(&authority, Some(ACCOUNT_ID)), "control"), "none");
}

#[test]
fn a_key_pinned_for_another_account_counts_as_unpinned() {
    let (_dir, authority) = fixture();
    let k = key();
    pin(&authority, &k, ACCOUNT_ID);
    // This machine is now joined as another account; the owner's key signs for that one.
    let other = grant(&k, |g| g["account"] = json!(OTHER_ACCOUNT));
    let refused =
        apply(&authority, &other, &target_for(Some(OTHER_ACCOUNT)), None, NOW).unwrap_err();
    assert_eq!(refused.reason, UNPINNED);
    assert_eq!(consent_of(&status(&authority, Some(OTHER_ACCOUNT)), "control"), "none");
    assert!(
        status_fields(&authority, Some(OTHER_ACCOUNT))["grantors"].as_array().unwrap().is_empty()
    );
}

/// What a platform, relay or carrier that holds no pinned key can make: a grant signed by its own
/// key, with the owner's name and even the pinned grantor's id.
#[test]
fn a_grant_the_control_plane_forged_is_refused() {
    let (_dir, authority) = fixture();
    let owner = key();
    pin(&authority, &owner, ACCOUNT_ID);
    let attacker = key();
    // Its own key and id, the owner's name: unpinned, and its ask shows the attacker's words.
    let own_id = grant(&attacker, |g| g["name"] = json!("Leo's MacBook Pro"));
    let refused = apply(&authority, &own_id, &target(), None, NOW).unwrap_err();
    assert_eq!(refused.reason, UNPINNED);
    assert_eq!(refused.words, Some(words(&public(&attacker))));
    assert_ne!(refused.words, Some(words(&public(&owner))));
    // The pinned grantor's id with the attacker's key as the hint: the pinned key decides.
    let owner_id = grantor_id(&public(&owner));
    let borrowed = grant(&attacker, |g| g["grantor"] = json!(owner_id));
    let refused = apply(&authority, &borrowed, &target(), None, NOW).unwrap_err();
    assert_eq!(refused.reason, SIGNATURE);
    let no_hint = grant(&attacker, |g| {
        g["grantor"] = json!(owner_id);
        g["publicKey"] = Value::Null;
    });
    assert_eq!(apply(&authority, &no_hint, &target(), None, NOW).unwrap_err().reason, SIGNATURE);
    let now = status(&authority, Some(ACCOUNT_ID));
    assert_eq!(consent_of(&now, "control"), "none");
    assert_eq!(consent_of(&now, "screen"), "none");
    // The only ask is the attacker's own id; it never replaced the owner's pin.
    let fields = status_fields(&authority, Some(ACCOUNT_ID));
    assert_eq!(fields["grantors"][0]["id"], json!(owner_id));
    assert_eq!(fields["grantorAsk"]["id"], json!(grantor_id(&public(&attacker))));
}

/// The gates read the store's status, so a signed off takes effect on the next circuit.
#[cfg(feature = "hub-carrier")]
#[test]
fn a_signed_off_refuses_the_next_circuit_with_consent_required() {
    use crate::session_service::{Decision, decide};
    let (_dir, authority) = fixture();
    let k = key();
    pin(&authority, &k, ACCOUNT_ID);
    apply(&authority, &grant(&k, |_| {}), &target(), None, NOW).unwrap();
    let on = status(&authority, Some(ACCOUNT_ID));
    assert!(crate::cmux_tui_service::admit(Some("127.0.0.1:7781"), &on, 7781).is_ok());
    let off = grant(&k, |g| {
        g["issuedAt"] = json!(NOW);
        g["control"] = json!("off");
        g["screen"] = json!("off");
    });
    let consent = apply(&authority, &off, &target(), None, NOW).unwrap();
    assert!(consent.control_granted_by.is_none() && consent.screen_granted_by.is_none());
    let off = status(&authority, Some(ACCOUNT_ID));
    let refused = crate::cmux_tui_service::admit(Some("127.0.0.1:7781"), &off, 7781).unwrap_err();
    assert_eq!(refused.reason, crate::cli::cloud_join::CONSENT_REQUIRED);
    match decide(&off, Some(ACCOUNT_ID)) {
        Decision::Refuse { refusal, .. } => {
            assert_eq!(refusal.reason, crate::cli::cloud_join::CONSENT_REQUIRED)
        }
        Decision::Admit => panic!("a workspace was admitted after the off"),
    }
    let revokes = log(&authority).iter().filter(|l| l["event"] == "revoke").count();
    assert_eq!(revokes, 2);
}

#[test]
fn local_consent_still_works_clears_the_remote_grant_and_is_logged() {
    let (_dir, authority) = fixture();
    let k = key();
    pin(&authority, &k, ACCOUNT_ID);
    apply(&authority, &grant(&k, |_| {}), &target(), None, NOW).unwrap();
    // A local On makes the surface the person's own here.
    let consent = authority.set("screen", true).unwrap();
    assert!(consent.screen_granted_by.is_none());
    assert!(consent.control_granted_by.is_some(), "the other surface keeps its grant");
    // A local Off revokes a remote On.
    let consent = authority.set("control", false).unwrap();
    assert!(consent.control_granted_by.is_none());
    let now = status(&authority, Some(ACCOUNT_ID));
    assert_eq!(consent_of(&now, "control"), "none");
    assert_eq!(consent_of(&now, "screen"), "granted");
    let local: Vec<Value> = log(&authority).into_iter().filter(|l| l["by"] == "local").collect();
    assert_eq!(local.len(), 2);
    assert_eq!(
        (local[0]["event"].as_str(), local[0]["surface"].as_str()),
        (Some("grant"), Some("screen"))
    );
    assert_eq!(
        (local[1]["event"].as_str(), local[1]["surface"].as_str()),
        (Some("revoke"), Some("control"))
    );
    // A screen granted here holds under any account.
    assert_eq!(consent_of(&status(&authority, Some(OTHER_ACCOUNT)), "screen"), "granted");
}

#[test]
fn a_remote_grant_reads_as_none_once_the_machine_is_joined_as_another_account() {
    let (_dir, authority) = fixture();
    let k = key();
    pin(&authority, &k, ACCOUNT_ID);
    apply(&authority, &grant(&k, |g| g["screen"] = json!("keep")), &target(), None, NOW).unwrap();
    assert_eq!(consent_of(&status(&authority, Some(ACCOUNT_ID)), "control"), "granted");
    assert_eq!(consent_of(&status(&authority, Some(OTHER_ACCOUNT)), "control"), "none");
    assert_eq!(consent_of(&status(&authority, None), "control"), "none");
}

#[test]
fn trust_pins_only_the_pending_ask_for_the_current_account() {
    let (_dir, authority) = fixture();
    let k = key();
    let id = grantor_id(&public(&k));
    assert!(matches!(
        trust(&authority, &id, true, Some(ACCOUNT_ID), NOW),
        Err(TrustError::Invalid(_))
    ));
    apply(&authority, &grant(&k, |_| {}), &target(), None, NOW).unwrap_err();
    let other = grantor_id(&public(&key()));
    assert!(matches!(
        trust(&authority, &other, true, Some(ACCOUNT_ID), NOW),
        Err(TrustError::Invalid(_))
    ));
    assert!(matches!(
        trust(&authority, &id, true, Some(OTHER_ACCOUNT), NOW),
        Err(TrustError::Invalid(_))
    ));
    assert!(matches!(trust(&authority, &id, true, None, NOW), Err(TrustError::Invalid(_))));
    let pinned = trust(&authority, &id, true, Some(ACCOUNT_ID), NOW).unwrap();
    assert_eq!(pinned["pinned"], true);
    let fields = status_fields(&authority, Some(ACCOUNT_ID));
    assert!(fields["grantorAsk"].is_null(), "the ask is answered");
    assert_eq!(fields["grantors"][0]["id"], json!(id));
    assert_eq!(fields["grantors"][0]["words"], json!(words(&public(&k))));
    // Once pinned, the same key's next grant counts; unpinned, it no longer does.
    apply(&authority, &grant(&k, |_| {}), &target(), None, NOW).unwrap();
    let unpinned = trust(&authority, &id, false, Some(ACCOUNT_ID), NOW).unwrap();
    assert_eq!(unpinned["unpinned"], true);
    let later = grant(&k, |g| g["issuedAt"] = json!(NOW));
    assert_eq!(apply(&authority, &later, &target(), None, NOW).unwrap_err().reason, UNPINNED);
    let events: Vec<String> =
        log(&authority).iter().map(|l| l["event"].as_str().unwrap().to_owned()).collect();
    assert!(events.contains(&"pinned".to_owned()) && events.contains(&"unpinned".to_owned()));
    // Dismissing the new ask leaves none.
    let dismissed = trust(&authority, &id, false, Some(ACCOUNT_ID), NOW).unwrap();
    assert_eq!(dismissed["dismissed"], true);
    assert!(status_fields(&authority, Some(ACCOUNT_ID))["grantorAsk"].is_null());
}

#[test]
fn the_log_keeps_its_last_lines() {
    let (_dir, authority) = fixture();
    for _ in 0..(MAX_LOG_LINES + 5) {
        authority.set("screen", true).unwrap();
    }
    assert_eq!(log(&authority).len(), MAX_LOG_LINES);
    assert_eq!(
        status_fields(&authority, Some(ACCOUNT_ID))["grantLog"].as_array().unwrap().len(),
        STATUS_LOG_LINES
    );
}

#[test]
fn the_carrier_request_handler_answers_status_and_applies_a_set() {
    let (_dir, authority) = fixture();
    let k = key();
    let id = grantor_id(&public(&k));
    let ask = |request: Value| {
        handle_request(&authority, &target(), Some("mbp"), request.to_string().as_bytes(), NOW)
    };
    let status = ask(json!({"op": "status", "grantor": id}));
    assert_eq!(status["ok"], true);
    assert_eq!(status["machineId"], MACHINE);
    assert_eq!(status["nodeKey"], json!(node_key(7)));
    assert_eq!(status["account"], ACCOUNT_ID);
    assert_eq!(status["host"], "mini-7");
    assert_eq!(status["control"], false);
    assert_eq!(status["grantor"]["pinned"], false);
    let refused = ask(json!({"op": "set", "grant": grant(&k, |_| {})}));
    assert_eq!(refused["ok"], false);
    assert_eq!(refused["reason"], UNPINNED);
    assert_eq!(refused["words"], json!(words(&public(&k))));
    trust(&authority, &id, true, Some(ACCOUNT_ID), NOW).unwrap();
    let set = ask(json!({"op": "set", "grant": grant(&k, |_| {})}));
    assert_eq!(set["ok"], true, "{set}");
    assert_eq!(set["control"], true);
    assert_eq!(set["screen"], true);
    assert_eq!(set["controlGrantedBy"]["grantor"], json!(id));
    assert_eq!(set["grantor"]["pinned"], true);
    assert!(set["grantLog"].as_array().is_some_and(|l| !l.is_empty()));
    let bad = handle_request(&authority, &target(), None, b"not json", NOW);
    assert_eq!(bad["reason"], "request.malformed");
    let big = vec![b' '; MAX_REQUEST_BYTES + 1];
    assert_eq!(
        handle_request(&authority, &target(), None, &big, NOW)["reason"],
        "request.too_large"
    );
    assert_eq!(ask(json!({"op": "pin"}))["reason"], "request.unknown");
}
