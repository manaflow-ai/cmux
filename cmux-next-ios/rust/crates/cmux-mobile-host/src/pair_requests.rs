//! The `pair-requests` service: a pairing request waiting on this Mac is answered from another
//! of the person's own devices, with no gesture on this Mac (Leo, 2026-11-22: "ok surely we dont
//! need to be bottled this hard by a click"). It applies the zero-touch rule of the screen-share
//! design (cmuxterm-hq `docs/design/remote-screen-share-zero-touch.md`, "zero actions on that
//! machine") to pairing, and the multi-machine design's "Approvals go where the person is".
//!
//! Who may answer, each checked here or before the channel opens:
//!
//! - **The same account.** The link was admitted only because the backend stamped the dial with
//!   this Mac's own user (`host::admitted`); a device of another account never gets a link here.
//! - **A device this Mac already trusts.** The service sits behind the pairing gate, so the
//!   asker passed `auth` with keys the person approved on this Mac. A Stack token alone opens
//!   nothing (audit B2 is unchanged): a phone signed in to the account but not paired here is
//!   refused `unpaired` before this service runs.
//! - **A machine with Control.** A Mac or Linux peer needs the `control` grant the person gave
//!   it here (`peer::need_for`), as for answering agents.
//! - **Not itself.** A device never answers its own request.
//!
//! What it answers: only a request hostd is waiting on now (the asking device's `auth` is still
//! open), named by its device id and the fingerprint of the key the Mac would show, so an
//! answer cannot land on other keys that asked under the same id. hostd tells the app
//! ([`Event::PairAnswer`]), which answers its waiting request as the person's Allow would; the
//! app's next `devices` line opens the waiting `auth`.
//!
//! Requests (the channel's open args, one answer then the channel closes):
//! - `{"action":"list"}` → `{"requests":[{"deviceId","name","kind","fingerprint","waitingMs"}]}`
//! - `{"action":"answer","deviceId":ID,"fingerprint":F,"allow":true|false}` → `{"ok":true}`

use std::sync::Mutex;
use std::time::Instant;

use bytes::Bytes;
use cmux_mobile_link::link::ChannelSender;
use serde_json::{Value, json};

use crate::control::Event;
use crate::pairing::{LinkAuth, Pairing, Refused};
use crate::peer::PeerKind;

/// At most this many waiting requests are listed (hostd's prompt limits keep far fewer).
pub const MAX_LISTED: usize = 32;

/// One request hostd asked the app about and still waits on.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WaitingRequest {
    pub device_id: String,
    pub name: String,
    pub kind: PeerKind,
    pub identity_key: String,
    pub approval_key: String,
    pub since: Instant,
}

impl WaitingRequest {
    /// The fingerprint the Mac's prompt shows: of the approval key for a phone, of the identity
    /// key for a machine (Swift `MobileHostPairRequest.shortFingerprint`, full length here).
    pub fn fingerprint(&self) -> String {
        let key = if self.kind.is_machine() || self.approval_key.is_empty() {
            &self.identity_key
        } else {
            &self.approval_key
        };
        fingerprint(key)
    }
}

/// SHA-256 of the key's bytes, its first 8 bytes as lowercase hex (Swift
/// `MobileHostPairedDevices.fingerprint`).
pub fn fingerprint(key_hex: &str) -> String {
    let bytes = (0..key_hex.len() / 2)
        .filter_map(|i| u8::from_str_radix(key_hex.get(i * 2..i * 2 + 2)?, 16).ok())
        .collect::<Vec<_>>();
    crate::seal::sha256_hex(&bytes)[..16].to_owned()
}

/// The requests hostd waits on now, shared by every link of this hostd.
#[derive(Debug, Default)]
pub struct Waiting {
    requests: Mutex<Vec<(u64, WaitingRequest)>>,
    next: std::sync::atomic::AtomicU64,
}

/// Removes its request from [`Waiting`] when the `auth` that asked ends, however it ends.
pub struct WaitingGuard<'a> {
    waiting: &'a Waiting,
    key: u64,
}

impl Drop for WaitingGuard<'_> {
    fn drop(&mut self) {
        self.waiting.lock().retain(|(key, _)| *key != self.key);
    }
}

impl Waiting {
    fn lock(&self) -> std::sync::MutexGuard<'_, Vec<(u64, WaitingRequest)>> {
        self.requests.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// `request` waits until the returned guard drops.
    pub fn hold(&self, request: WaitingRequest) -> WaitingGuard<'_> {
        let key = self.next.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        self.lock().push((key, request));
        WaitingGuard { waiting: self, key }
    }

    /// The waiting requests, oldest first.
    pub fn list(&self) -> Vec<WaitingRequest> {
        self.lock().iter().map(|(_, r)| r.clone()).collect()
    }
}

/// Who opened the channel: its device id (backend-stamped) and what passed `auth` on its link.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Asker<'a> {
    pub device_id: &'a str,
    /// `None`: no `auth` passed on this link (an unsupervised hostd's link).
    pub kind: Option<PeerKind>,
}

/// Answers one request; split from the I/O so tests can check every refusal.
pub fn handle(pairing: Option<&Pairing>, asker: &Asker<'_>, args: &Value) -> Result<Value, Refused> {
    let Some(pairing) = pairing else {
        return Err(("unavailable", "this Mac pairs devices only with the cmux app running".into()));
    };
    if asker.kind.is_none() {
        return Err(("unpaired", "pair this device with the Mac first (auth)".into()));
    }
    let text = |key: &str| args.get(key).and_then(Value::as_str).unwrap_or_default();
    let now = Instant::now();
    match text("action") {
        "list" => {
            let requests = pairing
                .waiting
                .list()
                .into_iter()
                .filter(|r| r.device_id != asker.device_id)
                .take(MAX_LISTED)
                .map(|r| {
                    json!({
                        "deviceId": r.device_id,
                        "name": r.name,
                        "kind": r.kind.as_str(),
                        "fingerprint": r.fingerprint(),
                        "waitingMs": u64::try_from(now.duration_since(r.since).as_millis()).unwrap_or(u64::MAX),
                    })
                })
                .collect::<Vec<_>>();
            Ok(json!({"requests": requests}))
        }
        "answer" => {
            let device_id = text("deviceId");
            let wanted = text("fingerprint");
            let Some(allow) = args.get("allow").and_then(Value::as_bool) else {
                return Err(("bad_request", "allow is true or false".into()));
            };
            if device_id.is_empty() || wanted.is_empty() {
                return Err(("bad_request", "expected deviceId and fingerprint".into()));
            }
            if device_id == asker.device_id {
                return Err(("forbidden", "a device cannot answer its own pairing request".into()));
            }
            let waiting = pairing.waiting.list();
            let Some(request) = waiting.iter().rev().find(|r| r.device_id == device_id) else {
                return Err((
                    "no_waiting_request",
                    format!("no pairing request from {device_id} is waiting on this Mac"),
                ));
            };
            // A short fingerprint (the 8 the prompt shows) is enough to name it; any other
            // value names other keys.
            let fingerprint = request.fingerprint();
            if wanted.len() < 8 || !fingerprint.starts_with(&wanted.to_ascii_lowercase()) {
                return Err((
                    "fingerprint_mismatch",
                    format!("{device_id} now asks with key {}, not {wanted}", &fingerprint[..8]),
                ));
            }
            (pairing.emit)(Event::PairAnswer {
                phone_device_id: request.device_id.clone(),
                identity_key: request.identity_key.clone(),
                approval_key: request.approval_key.clone(),
                allow,
                by_device_id: asker.device_id.to_owned(),
            });
            Ok(json!({"ok": true}))
        }
        _ => Err(("bad_request", "action is list or answer".into())),
    }
}

/// `cmux mobile pair-requests` run on this Mac itself: the same requests and answers, asked over
/// hostd's local link socket (`link_socket.rs`, `{"op":"pair-requests"}`), never over a link.
/// That socket is owner-only (`0600` in the daemon's `0700` folder) and checks the caller's
/// uid, so the asker is the OS user the app's own Allow button serves, on this Mac: the
/// same trust as that click (Leo, 2026-11-22: "surely we dont need to be bottled this hard by
/// a click. and esp on a single machine"). It asks as this Mac's own device id, so every refusal of [`handle`] still holds,
/// "a device cannot answer its own pairing request" included. Returns the service's answer,
/// or `{"error":CODE,"message":REASON}`.
pub fn answer_locally(pairing: Option<&Pairing>, args: &Value) -> Value {
    let device_id = pairing.map_or("", |p| p.mac_device_id.as_str());
    let asker = Asker { device_id, kind: Some(PeerKind::Mac) };
    match handle(pairing, &asker, args) {
        Ok(answer) => {
            if let Some(pairing) = pairing {
                record_answer(pairing, device_id, "mac", args);
            }
            answer
        }
        Err((code, message)) => json!({"error": code, "message": message}),
    }
}

/// An answer goes to the machine Activity log (a `list` does not).
fn record_answer(pairing: &Pairing, by: &str, kind: &'static str, args: &Value) {
    if args.get("action").and_then(Value::as_str) != Some("answer") {
        return;
    }
    pairing.activity.record(crate::activity::Entry {
        at_ms: crate::activity::now_ms(),
        peer: by.to_owned(),
        kind,
        direction: "in",
        service: "pair-requests".to_owned(),
        decision: "allowed".to_owned(),
        target: args.get("deviceId").and_then(Value::as_str).map(str::to_owned),
    });
}

/// The `pair-requests` service (behind the pairing gate; a machine needs `control`).
pub async fn serve(
    pairing: Option<&Pairing>,
    device_id: &str,
    link: &LinkAuth,
    args: &Value,
    sender: &ChannelSender,
) -> Result<(), Refused> {
    let kind = link.peer().map(|(kind, _)| kind);
    let answer = handle(pairing, &Asker { device_id, kind }, args)?;
    if let Some(pairing) = pairing {
        record_answer(pairing, device_id, kind.map_or("phone", PeerKind::as_str), args);
    }
    let _ = sender.send(Bytes::from(answer.to_string())).await;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    const KEY_A: &str = "04aa";
    const KEY_B: &str = "04bb";

    fn pairing() -> (Pairing, Arc<Mutex<Vec<Event>>>) {
        let events = Arc::new(Mutex::new(Vec::new()));
        let sink = Arc::clone(&events);
        let pairing = Pairing::new(
            "mac".into(),
            tokio::sync::watch::channel(None).1,
            Arc::new(move |event| sink.lock().unwrap().push(event)),
        );
        (pairing, events)
    }

    fn request(id: &str) -> WaitingRequest {
        WaitingRequest {
            device_id: id.into(),
            name: "Probe iPhone".into(),
            kind: PeerKind::Phone,
            identity_key: KEY_A.into(),
            approval_key: KEY_B.into(),
            since: Instant::now(),
        }
    }

    const PAIRED_PHONE: Asker<'static> = Asker { device_id: "leos-phone", kind: Some(PeerKind::Phone) };

    fn answer(id: &str, fingerprint: &str, allow: bool) -> Value {
        json!({"action": "answer", "deviceId": id, "fingerprint": fingerprint, "allow": allow})
    }

    #[test]
    fn a_paired_device_of_the_account_approves_a_waiting_request() {
        let (pairing, events) = pairing();
        let _held = pairing.waiting.hold(request("probe"));
        let listed = handle(Some(&pairing), &PAIRED_PHONE, &json!({"action": "list"})).unwrap();
        let fingerprint = listed["requests"][0]["fingerprint"].as_str().unwrap().to_owned();
        assert_eq!(fingerprint, fingerprint_of_b());
        assert_eq!(listed["requests"][0]["deviceId"], "probe");
        // The 8 characters the Mac's prompt shows name it.
        assert_eq!(
            handle(Some(&pairing), &PAIRED_PHONE, &answer("probe", &fingerprint[..8], true)).unwrap(),
            json!({"ok": true})
        );
        assert_eq!(
            *events.lock().unwrap(),
            vec![Event::PairAnswer {
                phone_device_id: "probe".into(),
                identity_key: KEY_A.into(),
                approval_key: KEY_B.into(),
                allow: true,
                by_device_id: "leos-phone".into(),
            }]
        );
    }

    fn fingerprint_of_b() -> String {
        // SHA-256 of the bytes 04 bb, first 8 bytes.
        crate::seal::sha256_hex(&[0x04, 0xbb])[..16].to_owned()
    }

    #[test]
    fn a_device_this_mac_never_paired_is_refused() {
        // What a Stack token of any account alone gets: a link with no `auth` passed. (A device of
        // another account never gets a link at all: `host::admitted`, tests/host.rs.)
        let (pairing, events) = pairing();
        let _held = pairing.waiting.hold(request("probe"));
        let stranger = Asker { device_id: "other-phone", kind: None };
        for args in [json!({"action": "list"}), answer("probe", &fingerprint_of_b(), true)] {
            assert_eq!(handle(Some(&pairing), &stranger, &args).unwrap_err().0, "unpaired");
        }
        assert!(events.lock().unwrap().is_empty());
    }

    #[test]
    fn no_waiting_request_is_a_clear_error() {
        let (pairing, events) = pairing();
        let (code, reason) =
            handle(Some(&pairing), &PAIRED_PHONE, &answer("probe", "abcdef01", true)).unwrap_err();
        assert_eq!(code, "no_waiting_request");
        assert_eq!(reason, "no pairing request from probe is waiting on this Mac");
        // Once the asking `auth` ended, its request no longer waits.
        drop(pairing.waiting.hold(request("probe")));
        assert_eq!(
            handle(Some(&pairing), &PAIRED_PHONE, &answer("probe", &fingerprint_of_b(), true)).unwrap_err().0,
            "no_waiting_request"
        );
        assert_eq!(
            handle(Some(&pairing), &PAIRED_PHONE, &json!({"action": "list"})).unwrap(),
            json!({"requests": []})
        );
        assert!(events.lock().unwrap().is_empty());
    }

    #[test]
    fn other_keys_under_the_same_id_and_self_answers_are_refused() {
        let (pairing, events) = pairing();
        let _held = pairing.waiting.hold(request("probe"));
        assert_eq!(
            handle(Some(&pairing), &PAIRED_PHONE, &answer("probe", "00000000", true)).unwrap_err().0,
            "fingerprint_mismatch"
        );
        assert_eq!(
            handle(Some(&pairing), &PAIRED_PHONE, &answer("probe", "abc", true)).unwrap_err().0,
            "fingerprint_mismatch"
        );
        let itself = Asker { device_id: "probe", kind: Some(PeerKind::Phone) };
        assert_eq!(
            handle(Some(&pairing), &itself, &answer("probe", &fingerprint_of_b(), true)).unwrap_err().0,
            "forbidden"
        );
        // Its own request is not listed to it either.
        assert_eq!(
            handle(Some(&pairing), &itself, &json!({"action": "list"})).unwrap(),
            json!({"requests": []})
        );
        assert_eq!(
            handle(
                Some(&pairing),
                &PAIRED_PHONE,
                &json!({"action": "answer", "deviceId": "probe",
                                                                  "fingerprint": "abcdef01"})
            )
            .unwrap_err()
            .0,
            "bad_request"
        );
        assert!(events.lock().unwrap().is_empty());
    }

    #[test]
    fn a_deny_is_forwarded_and_an_unsupervised_host_answers_nothing() {
        let (pairing, events) = pairing();
        let _held = pairing.waiting.hold(request("probe"));
        handle(Some(&pairing), &PAIRED_PHONE, &answer("probe", &fingerprint_of_b(), false)).unwrap();
        assert!(matches!(events.lock().unwrap()[0], Event::PairAnswer { allow: false, .. }));
        assert_eq!(handle(None, &PAIRED_PHONE, &json!({"action": "list"})).unwrap_err().0, "unavailable");
    }

    #[test]
    fn this_macs_owner_answers_locally_with_every_refusal_kept() {
        let (pairing, events) = pairing();
        let _held = pairing.waiting.hold(request("probe"));
        let listed = answer_locally(Some(&pairing), &json!({"action": "list"}));
        let fingerprint = listed["requests"][0]["fingerprint"].as_str().unwrap().to_owned();
        assert_eq!(fingerprint, fingerprint_of_b());
        // The fingerprint is still required, and still must name the waiting key.
        assert_eq!(
            answer_locally(Some(&pairing), &json!({"action": "answer", "deviceId": "probe", "allow": true}))
                ["error"],
            "bad_request"
        );
        assert_eq!(
            answer_locally(Some(&pairing), &answer("probe", "00000000", true))["error"],
            "fingerprint_mismatch"
        );
        assert!(events.lock().unwrap().is_empty());
        assert_eq!(
            answer_locally(Some(&pairing), &answer("probe", &fingerprint[..8], true)),
            json!({"ok": true})
        );
        assert_eq!(
            *events.lock().unwrap(),
            vec![Event::PairAnswer {
                phone_device_id: "probe".into(),
                identity_key: KEY_A.into(),
                approval_key: KEY_B.into(),
                allow: true,
                by_device_id: "mac".into(),
            }]
        );
        assert_eq!(pairing.activity.recent().len(), 1);
    }

    #[test]
    fn the_local_path_refuses_what_the_service_refuses() {
        let (pairing, events) = pairing();
        // A request under this Mac's own id cannot be answered by this Mac.
        let _held = pairing.waiting.hold(request("mac"));
        assert_eq!(
            answer_locally(Some(&pairing), &answer("mac", &fingerprint_of_b(), true)),
            json!({"error": "forbidden", "message": "a device cannot answer its own pairing request"})
        );
        assert_eq!(answer_locally(Some(&pairing), &json!({"action": "list"})), json!({"requests": []}));
        assert_eq!(
            answer_locally(Some(&pairing), &answer("probe", "abcdef01", true))["error"],
            "no_waiting_request"
        );
        assert_eq!(answer_locally(None, &json!({"action": "list"}))["error"], "unavailable");
        assert!(events.lock().unwrap().is_empty());
        assert!(pairing.activity.recent().is_empty());
    }

    #[test]
    fn a_machine_request_is_named_by_its_identity_key() {
        let mut machine = request("studio");
        machine.kind = PeerKind::Mac;
        assert_eq!(machine.fingerprint(), crate::seal::sha256_hex(&[0x04, 0xaa])[..16]);
    }

    #[test]
    fn machines_need_control_to_open_it() {
        assert_eq!(crate::peer::allows(&[], "pair-requests"), Err("not_granted"));
        assert_eq!(crate::peer::allows(&[crate::peer::Grant::View], "pair-requests"), Err("not_granted"));
        assert_eq!(crate::peer::allows(&[crate::peer::Grant::Control], "pair-requests"), Ok(()));
    }
}
