//! The phone stand-in's mailbox send mode (`cmux-mobile-dial --via-mailbox`).
//!
//! It sends chat `send` items the way the phone does while its Mac sleeps:
//! `cmux-mobile-link`'s `mailbox_client` builds, signs and seals each item to
//! the Mac's box key (checked against the Mac's pinned identity key), and its
//! `Tracker` posts it to `POST /v1/devices/:mac/mailbox` and polls
//! `GET /v1/devices/:mac/mailbox/:id` until the Mac's signed ack (or expiry).
//! No link is opened: this is the path that works with the Mac asleep.
//!
//!   cmux-mobile-dial --via-mailbox --base-url URL --token-file PATH --mac MAC
//!            --phone PHONE_ID --phone-key-file PATH --mac-keys-file PATH
//!            --session SESSION_ID [--text T] [--count N] [--wait SECS] [--summary]
//!   cmux-mobile-dial --new-phone-key
//!   cmux-mobile-dial --mac-keys MAC PRIVATE_HEX PUBLIC_HEX
//!
//! `--phone-key-file` holds `{"privateKey", "publicKey"}` (hex: the 32-byte
//! scalar and the 65-byte X9.63 point), as `--new-phone-key` prints; the Mac
//! trusts it through the control line `{"type":"devices","devices":[{"id":
//! PHONE_ID,"identity_key":publicKey}]}`. `--mac-keys-file` holds what a
//! phone pins at pairing, `{"macKey", "macBoxKey", "macBoxSignature"}`, as
//! `--mac-keys` prints from the identity the Mac is given
//! (`{"type":"mac_identity",...}`).
//!
//! Prints one JSON line per item: its id, the hub's seq, the final state, the
//! milliseconds from the first post to that state (`post_to_final_ms`), the
//! Unix milliseconds the hub took it (`enqueued_unix_ms`) and the dial saw it
//! final (`final_unix_ms`), and the time between (`enqueue_to_final_ms`).
//! `applied` means the Mac's signed ack checked against its pinned identity
//! key (`macKey`); an unsigned or forged outcome is `notconfirmed`.
//! With `--summary` a last line `{"kind":"mailbox_summary",...}` gives the
//! enqueue to applied p50, p95 and max over the applied items, how many were
//! applied, whether the hub's seqs follow send order, and repeated seqs.

use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result, anyhow, bail};
use cmux_mobile_link::mailbox_client::{
    Action, ItemSpec, Request, Signer, State, Step, Target, Tracker, build, trusted_box_key,
};
use serde_json::{Value, json};

use crate::pairing::MacIdentity;

/// The phone's identity key, signing as `MacIdentity` does (P-256, raw r || s).
struct PhoneSigner(MacIdentity);

impl Signer for PhoneSigner {
    fn sign(&self, message: &[u8]) -> Result<Vec<u8>, String> {
        let hex = self.0.sign(message).ok_or("signing failed")?;
        crate::seal::unhex(&hex).ok_or_else(|| "not hex".to_owned())
    }
}

pub struct Args {
    pub base_url: String,
    pub token: String,
    pub mac: String,
    pub phone: String,
    pub phone_key: Value,
    pub mac_keys: Value,
    pub session: String,
    pub text: String,
    pub count: usize,
    pub wait: Duration,
    pub summary: bool,
}

/// True when `argv` asks for one of this module's modes.
pub fn wanted(argv: &[String]) -> bool {
    argv.iter().any(|a| matches!(a.as_str(), "--via-mailbox" | "--new-phone-key" | "--mac-keys"))
}

/// A fresh phone identity key, as `--phone-key-file` reads it.
pub fn new_phone_key() -> Result<Value> {
    let secret = crate::seal::random_secret().map_err(|e| anyhow!("{e:?}"))?;
    Ok(json!({
        "privateKey": crate::seal::hex(&secret.to_bytes()),
        "publicKey": crate::seal::point_hex(&secret.public_key()),
    }))
}

/// What a phone pins for `mac` at pairing, from the identity key the Mac runs with.
pub fn mac_keys(mac: &str, private_hex: &str, public_hex: &str) -> Result<Value> {
    let identity = MacIdentity::from_raw(private_hex, public_hex).context("not a P-256 identity key")?;
    let statement = crate::seal::box_key_message(&mac.to_lowercase(), identity.box_public_key());
    Ok(json!({
        "macKey": identity.public_key(),
        "macBoxKey": identity.box_public_key(),
        "macBoxSignature": identity.sign(&statement).context("signing failed")?,
    }))
}

fn read_json(path: &str) -> Result<Value> {
    let text = std::fs::read_to_string(path).with_context(|| format!("reading {path}"))?;
    serde_json::from_str(&text).with_context(|| format!("{path} is not JSON"))
}

/// Parses `argv` (without the program name) for `--via-mailbox`.
pub fn parse(argv: &[String]) -> Result<Args> {
    let mut it = argv.iter();
    let (mut base_url, mut token_file, mut mac, mut phone) = (None, None, None, None);
    let (mut phone_key, mut mac_keys, mut session) = (None, None, None);
    let (mut text, mut count, mut wait) = ("cmux mailbox probe".to_owned(), 1usize, 900u64);
    let mut summary = false;
    while let Some(flag) = it.next() {
        let mut value = || it.next().cloned().with_context(|| format!("{flag} needs a value"));
        match flag.as_str() {
            "--via-mailbox" => {}
            "--base-url" => base_url = Some(value()?),
            "--token-file" => token_file = Some(value()?),
            "--mac" => mac = Some(value()?),
            "--phone" => phone = Some(value()?),
            "--phone-key-file" => phone_key = Some(read_json(&value()?)?),
            "--mac-keys-file" => mac_keys = Some(read_json(&value()?)?),
            "--session" => session = Some(value()?),
            "--text" => text = value()?,
            "--count" => count = value()?.parse()?,
            "--wait" => wait = value()?.parse()?,
            "--summary" => summary = true,
            // The link flags the other mode takes mean nothing here.
            "--team" | "--transport" | "--bytes" | "--pings" => {
                value()?;
            }
            other => bail!("unknown argument {other} for --via-mailbox"),
        }
    }
    let token_file = token_file.context("--token-file is required")?;
    let token = std::fs::read_to_string(&token_file).with_context(|| format!("reading {token_file}"))?;
    if count == 0 {
        bail!("--count is at least 1");
    }
    Ok(Args {
        base_url: base_url.context("--base-url is required")?.trim_end_matches('/').to_owned(),
        token: token.trim().to_owned(),
        mac: mac.context("--mac is required")?,
        phone: phone.context("--phone is required")?,
        phone_key: phone_key.context("--phone-key-file is required")?,
        mac_keys: mac_keys.context("--mac-keys-file is required")?,
        session: session.context("--session is required")?,
        text,
        count,
        wait: Duration::from_secs(wait),
        summary,
    })
}

fn unix_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

fn field<'a>(value: &'a Value, key: &str) -> Option<&'a str> {
    value.get(key).and_then(Value::as_str)
}

/// The items to send, built and sealed the phone's way, in send order.
pub fn items(args: &Args, now: u64) -> Result<Vec<cmux_mobile_link::mailbox_client::SealedItem>> {
    let box_key = trusted_box_key(
        &args.mac,
        field(&args.mac_keys, "macBoxKey"),
        field(&args.mac_keys, "macBoxSignature"),
        field(&args.mac_keys, "macKey"),
    )?;
    let signer = PhoneSigner(
        MacIdentity::from_raw(
            field(&args.phone_key, "privateKey").context("privateKey")?,
            field(&args.phone_key, "publicKey").context("publicKey")?,
        )
        .context("the phone key is not a P-256 key pair")?,
    );
    (0..args.count)
        .map(|n| {
            let text = if args.count == 1 { args.text.clone() } else { format!("{} {}", args.text, n + 1) };
            let spec = ItemSpec {
                id: uuid::Uuid::new_v4().to_string(),
                mac: args.mac.clone(),
                phone: args.phone.clone(),
                kind: "send".into(),
                target: Target { session_id: Some(args.session.clone()), ..Target::default() },
                action: Action::Text { text, steer: None },
                approval: None,
                nonce: None,
                issued_at: now,
                lifetime_secs: None,
            };
            Ok(build(&spec, &box_key, &signer, now)?)
        })
        .collect()
}

fn state_name(state: &State) -> String {
    match state {
        State::Rejected { reason } => format!("rejected:{reason}"),
        State::Failed { code } => format!("failed:{code}"),
        other => format!("{other:?}").to_lowercase(),
    }
}

async fn send(
    http: &reqwest::Client,
    args: &Args,
    request: &Request,
) -> Result<(u16, String), reqwest::Error> {
    let response = match request {
        Request::Post { path, body } => http
            .post(format!("{}{path}", args.base_url))
            .bearer_auth(&args.token)
            .header("content-type", "application/json")
            .body(body.clone()),
        Request::Poll { path } => http.get(format!("{}{path}", args.base_url)).bearer_auth(&args.token),
    }
    .timeout(Duration::from_secs(20))
    .send()
    .await?;
    let status = response.status().as_u16();
    Ok((status, response.text().await.unwrap_or_default()))
}

/// One item's tracker and when it moved: the hub took it, and it was final.
pub struct Sent {
    pub tracker: Tracker,
    pub enqueued_unix_ms: Option<u64>,
    pub final_unix_ms: Option<u64>,
    pub settled: Option<Duration>,
}

impl Sent {
    /// Marks the times the item's state just reached.
    fn note(&mut self, started: Instant) {
        let now = unix_ms();
        if self.enqueued_unix_ms.is_none() && !matches!(self.tracker.state(), State::Posting) {
            self.enqueued_unix_ms = Some(now);
        }
        if self.settled.is_none() && self.tracker.state().is_final() {
            self.settled = Some(started.elapsed());
            self.final_unix_ms = Some(now);
        }
    }

    fn row(&self) -> Value {
        let enqueue_to_final = match (self.enqueued_unix_ms, self.final_unix_ms) {
            (Some(q), Some(f)) => Some(f.saturating_sub(q)),
            _ => None,
        };
        json!({
            "id": self.tracker.id(),
            "seq": self.tracker.seq(),
            "state": state_name(self.tracker.state()),
            "final": self.tracker.state().is_final(),
            "post_to_final_ms": self.settled.map(|d| d.as_millis() as u64),
            "enqueued_unix_ms": self.enqueued_unix_ms,
            "final_unix_ms": self.final_unix_ms,
            "enqueue_to_final_ms": enqueue_to_final,
        })
    }
}

/// The trackers for `items`, each checking the Mac's signed ack against the
/// pinned identity key (`macKey` in `--mac-keys-file`): without it no outcome
/// would count as applied.
pub fn trackers(args: &Args, now_ms: u64) -> Result<Vec<Sent>> {
    let pinned = field(&args.mac_keys, "macKey").context("macKey")?.to_owned();
    Ok(items(args, now_ms / 1000)?
        .into_iter()
        .map(|item| Sent {
            tracker: Tracker::new(item, Some(pinned.clone()), false, now_ms),
            enqueued_unix_ms: None,
            final_unix_ms: None,
            settled: None,
        })
        .collect())
}

/// Posts every item in order (each post answered before the next, so the hub's
/// seqs follow send order), then polls them all until each is final or `--wait` ends.
pub async fn run(args: &Args) -> Result<Vec<Value>> {
    let http = cmux_mobile_link::api::ApiClient::http_client();
    let started = Instant::now();
    let deadline = started + args.wait;
    let mut sent = trackers(args, unix_ms())?;
    // The posts, in order: a tracker that cannot post yet waits its turn, so a
    // later item never reaches the hub first.
    for item in sent.iter_mut() {
        while matches!(item.tracker.state(), State::Posting) && Instant::now() < deadline {
            match item.tracker.next(unix_ms()) {
                Step::Send(request @ Request::Post { .. }) => match send(&http, args, &request).await {
                    Ok((status, body)) => item.tracker.on_post(status, &body, unix_ms()),
                    Err(_) => item.tracker.on_transport_error(unix_ms()),
                },
                Step::Wait { until_ms } => {
                    tokio::time::sleep(Duration::from_millis(until_ms.saturating_sub(unix_ms()).min(1_000)))
                        .await;
                }
                Step::Send(Request::Poll { .. }) | Step::Done => break,
            }
            item.note(started);
        }
        item.note(started);
    }
    while Instant::now() < deadline {
        let mut soonest: Option<u64> = None;
        for item in sent.iter_mut() {
            if item.settled.is_some() {
                continue;
            }
            match item.tracker.next(unix_ms()) {
                Step::Send(request) => {
                    let answer = send(&http, args, &request).await;
                    match (&request, answer) {
                        (Request::Post { .. }, Ok((status, body))) => {
                            item.tracker.on_post(status, &body, unix_ms());
                        }
                        (Request::Poll { .. }, Ok((status, body))) => {
                            item.tracker.on_poll(status, &body, unix_ms());
                        }
                        (_, Err(_)) => item.tracker.on_transport_error(unix_ms()),
                    }
                    soonest = Some(unix_ms());
                }
                Step::Wait { until_ms } => soonest = Some(soonest.map_or(until_ms, |s| s.min(until_ms))),
                Step::Done => {}
            }
            item.note(started);
        }
        let Some(until) = soonest else { break };
        tokio::time::sleep(Duration::from_millis(until.saturating_sub(unix_ms()).min(1_000))).await;
    }
    Ok(sent.iter().map(Sent::row).collect())
}

/// The nearest-rank percentile `p` (0 to 100) of `sorted`, which is ascending.
pub fn percentile(sorted: &[u64], p: u32) -> Option<u64> {
    if sorted.is_empty() {
        return None;
    }
    let rank = (u64::from(p.min(100)) * sorted.len() as u64).div_ceil(100).max(1);
    sorted.get(rank as usize - 1).copied()
}

/// The `--summary` line over the per-item rows `run` returns.
pub fn summary(rows: &[Value]) -> Value {
    let mut latencies: Vec<u64> = rows
        .iter()
        .filter(|r| r["state"] == "applied")
        .filter_map(|r| r["enqueue_to_final_ms"].as_u64())
        .collect();
    latencies.sort_unstable();
    let seqs: Vec<u64> = rows.iter().filter_map(|r| r["seq"].as_u64()).collect();
    let in_order = seqs.len() == rows.len() && seqs.windows(2).all(|w| w[0] < w[1]);
    let mut unique = seqs.clone();
    unique.sort_unstable();
    unique.dedup();
    json!({
        "kind": "mailbox_summary",
        "items": rows.len(),
        "applied": latencies.len(),
        "not_applied": rows.len() - latencies.len(),
        "seqs_in_order": in_order,
        "repeated_seqs": seqs.len() - unique.len(),
        "enqueue_to_applied_ms": {
            "p50": percentile(&latencies, 50),
            "p95": percentile(&latencies, 95),
            "max": latencies.last(),
        },
    })
}

/// The `--via-mailbox`, `--new-phone-key` and `--mac-keys` entry point. Exits 1
/// when an item did not end applied.
pub async fn main(argv: &[String]) -> Result<()> {
    if argv.iter().any(|a| a == "--new-phone-key") {
        println!("{}", new_phone_key()?);
        return Ok(());
    }
    if let Some(at) = argv.iter().position(|a| a == "--mac-keys") {
        let [mac, private, public] = [1, 2, 3].map(|i| argv.get(at + i).map(String::as_str));
        let (Some(mac), Some(private), Some(public)) = (mac, private, public) else {
            bail!("--mac-keys MAC PRIVATE_HEX PUBLIC_HEX");
        };
        println!("{}", mac_keys(mac, private, public)?);
        return Ok(());
    }
    let args = parse(argv)?;
    let results = run(&args).await?;
    let all_applied = results.iter().all(|r| r["state"] == "applied");
    for result in &results {
        println!("{result}");
    }
    if args.summary {
        println!("{}", summary(&results));
    }
    if !all_applied {
        std::process::exit(1);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(phone_key: Value, mac_keys: Value, count: usize) -> Args {
        Args {
            base_url: "http://127.0.0.1:1".into(),
            token: "t".into(),
            mac: "mac-1".into(),
            phone: "phone-1".into(),
            phone_key,
            mac_keys,
            session: "s-1".into(),
            text: "hi".into(),
            count,
            wait: Duration::from_secs(1),
            summary: false,
        }
    }

    /// The items the stand-in seals open, verify and parse on the Mac as the phone's do.
    #[test]
    fn the_stand_ins_items_pass_the_macs_checks() {
        let phone_key = new_phone_key().unwrap();
        let secret = crate::seal::random_secret().unwrap();
        let (private, public) =
            (crate::seal::hex(&secret.to_bytes()), crate::seal::point_hex(&secret.public_key()));
        let identity = MacIdentity::from_raw(&private, &public).unwrap();
        let pinned = mac_keys("mac-1", &private, &public).unwrap();
        let sealed = items(&args(phone_key.clone(), pinned, 3), super::unix_ms() / 1000).unwrap();
        assert_eq!(sealed.len(), 3);
        let trust = crate::pairing::DeviceTrust {
            devices: vec![crate::pairing::TrustedDevice {
                id: "phone-1".into(),
                identity_key: phone_key["publicKey"].as_str().unwrap().into(),
                ..Default::default()
            }],
            denied: vec![],
        };
        for item in &sealed {
            let on_hub = cmux_mobile_link::signaling::MailboxItem {
                id: item.id.clone(),
                from: item.phone.clone(),
                sealed: item.sealed.clone(),
                at: None,
                seq: None,
            };
            crate::mailbox::verify(&on_hub, "mac-1", &identity, &trust, super::unix_ms() / 1000)
                .expect("the Mac takes the stand-in's item");
        }
    }

    /// A box key the pinned identity did not sign is refused before anything is sealed.
    #[test]
    fn a_box_key_the_pinned_key_did_not_sign_is_refused() {
        let secret = crate::seal::random_secret().unwrap();
        let (private, public) =
            (crate::seal::hex(&secret.to_bytes()), crate::seal::point_hex(&secret.public_key()));
        let mut pinned = mac_keys("mac-1", &private, &public).unwrap();
        pinned["macKey"] = new_phone_key().unwrap()["publicKey"].clone();
        assert!(items(&args(new_phone_key().unwrap(), pinned, 1), super::unix_ms() / 1000).is_err());
    }

    /// A Mac key pair, and what a phone pins for it.
    fn mac() -> (MacIdentity, Value) {
        let secret = crate::seal::random_secret().unwrap();
        let (private, public) =
            (crate::seal::hex(&secret.to_bytes()), crate::seal::point_hex(&secret.public_key()));
        (MacIdentity::from_raw(&private, &public).unwrap(), mac_keys("mac-1", &private, &public).unwrap())
    }

    fn ack(identity: &MacIdentity, id: &str) -> String {
        identity.sign(&crate::mailbox::ack_message("mac-1", id, true, None)).unwrap()
    }

    /// The dial pins the Mac's identity key, so the Mac's signed ack reads as
    /// applied and an unsigned or stranger-signed one as not confirmed.
    #[test]
    fn an_applied_outcome_counts_only_with_the_pinned_macs_signature() {
        let (identity, pinned) = mac();
        let (stranger, _) = mac();
        let now = super::unix_ms();
        let mut sent = trackers(&args(new_phone_key().unwrap(), pinned, 3), now).unwrap();
        let bodies: Vec<String> = sent
            .iter()
            .enumerate()
            .map(|(n, s)| {
                let id = s.tracker.id().to_owned();
                match n {
                    0 => json!({"state": "applied", "seq": 1, "sig": ack(&identity, &id)}),
                    1 => json!({"state": "applied", "seq": 2}),
                    _ => json!({"state": "applied", "seq": 3, "sig": ack(&stranger, &id)}),
                }
                .to_string()
            })
            .collect();
        let states: Vec<State> = sent
            .iter_mut()
            .zip(bodies)
            .map(|(s, body)| {
                assert!(matches!(s.tracker.next(now), Step::Send(Request::Post { .. })));
                s.tracker.on_post(200, r#"{"queued":true,"seq":1}"#, now);
                assert!(matches!(s.tracker.next(now + 1_000), Step::Send(Request::Poll { .. })));
                s.tracker.on_poll(200, &body, now + 1_000);
                s.tracker.state().clone()
            })
            .collect();
        assert_eq!(states, vec![State::Applied, State::NotConfirmed, State::NotConfirmed]);
    }

    #[test]
    fn percentiles_are_nearest_rank() {
        assert_eq!(percentile(&[], 50), None);
        assert_eq!(percentile(&[7], 95), Some(7));
        let ten: Vec<u64> = (1..=10).collect();
        assert_eq!(
            (percentile(&ten, 50), percentile(&ten, 95), percentile(&ten, 100)),
            (Some(5), Some(10), Some(10))
        );
        let twenty: Vec<u64> = (1..=20).collect();
        assert_eq!(percentile(&twenty, 95), Some(19));
    }

    #[test]
    fn the_summary_counts_applied_items_and_checks_seq_order() {
        let row =
            |seq: u64, state: &str, ms: u64| json!({"seq": seq, "state": state, "enqueue_to_final_ms": ms});
        let rows = [
            row(1, "applied", 300),
            row(2, "applied", 100),
            row(3, "applied", 200),
            row(4, "expired", 9_000),
        ];
        let s = summary(&rows);
        assert_eq!(
            (s["items"].as_u64(), s["applied"].as_u64(), s["not_applied"].as_u64()),
            (Some(4), Some(3), Some(1))
        );
        assert_eq!(s["enqueue_to_applied_ms"], json!({"p50": 200, "p95": 300, "max": 300}));
        assert_eq!((s["seqs_in_order"].as_bool(), s["repeated_seqs"].as_u64()), (Some(true), Some(0)));
        let s = summary(&[row(2, "applied", 1), row(1, "applied", 1), row(1, "applied", 1)]);
        assert_eq!((s["seqs_in_order"].as_bool(), s["repeated_seqs"].as_u64()), (Some(false), Some(1)));
    }

    /// A hub on loopback that holds every item while the Mac is asleep, then
    /// has the Mac apply them in seq order with signed acks, as the drain does.
    async fn sleeping_hub(
        identity: MacIdentity,
        asleep: Duration,
    ) -> (String, std::sync::Arc<std::sync::Mutex<Vec<String>>>) {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let posted = std::sync::Arc::new(std::sync::Mutex::new(Vec::<String>::new()));
        let held = posted.clone();
        let wakes = Instant::now() + asleep;
        let identity = std::sync::Arc::new(identity);
        tokio::spawn(async move {
            loop {
                let Ok((mut conn, _)) = listener.accept().await else { return };
                let (held, identity) = (held.clone(), identity.clone());
                tokio::spawn(async move {
                    let mut buf = Vec::new();
                    let mut chunk = [0u8; 4096];
                    let (head, body) = loop {
                        let Ok(n) = conn.read(&mut chunk).await else { return };
                        if n == 0 {
                            return;
                        }
                        buf.extend_from_slice(&chunk[..n]);
                        let text = String::from_utf8_lossy(&buf).to_string();
                        let Some(end) = text.find("\r\n\r\n") else { continue };
                        let length = text[..end]
                            .lines()
                            .find_map(|l| {
                                l.to_lowercase().strip_prefix("content-length:").map(|v| v.trim().to_owned())
                            })
                            .and_then(|v| v.parse::<usize>().ok())
                            .unwrap_or(0);
                        if buf.len() >= end + 4 + length {
                            break (text[..end].to_owned(), text[end + 4..end + 4 + length].to_owned());
                        }
                    };
                    let line = head.lines().next().unwrap_or_default().to_owned();
                    let answer = if line.starts_with("POST /v1/devices/mac-1/mailbox ") {
                        let id =
                            serde_json::from_str::<Value>(&body).unwrap()["id"].as_str().unwrap().to_owned();
                        let mut held = held.lock().unwrap();
                        let seq = match held.iter().position(|h| *h == id) {
                            Some(at) => at + 1,
                            None => {
                                held.push(id);
                                held.len()
                            }
                        };
                        json!({"queued": true, "delivered": false, "seq": seq})
                    } else if let Some(id) = line.strip_prefix("GET /v1/devices/mac-1/mailbox/") {
                        let id = id.split(' ').next().unwrap_or_default();
                        let seq = held.lock().unwrap().iter().position(|h| h == id).map(|at| at + 1);
                        if Instant::now() < wakes {
                            json!({"state": "queued", "seq": seq})
                        } else {
                            let sig =
                                identity.sign(&crate::mailbox::ack_message("mac-1", id, true, None)).unwrap();
                            json!({"state": "applied", "seq": seq, "sig": sig})
                        }
                    } else {
                        json!({"error": "not_found"})
                    }
                    .to_string();
                    let reply = format!(
                        "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{answer}",
                        answer.len()
                    );
                    let _ = conn.write_all(reply.as_bytes()).await;
                    let _ = conn.shutdown().await;
                });
            }
        });
        (url, posted)
    }

    /// N sends posted while the Mac sleeps are held, each once and in send
    /// order, and end applied (signed) after the wake; each item's enqueue to
    /// applied covers the sleep, and the summary reports its p50 and p95.
    #[tokio::test]
    async fn sends_posted_while_the_mac_sleeps_end_applied_in_order_after_the_wake() {
        let (identity, pinned) = mac();
        let asleep = Duration::from_millis(1_500);
        let (url, posted) = sleeping_hub(identity, asleep).await;
        let mut a = args(new_phone_key().unwrap(), pinned, 4);
        a.base_url = url;
        a.wait = Duration::from_secs(30);
        let rows = tokio::time::timeout(Duration::from_secs(60), run(&a)).await.expect("run ends").unwrap();
        assert_eq!(posted.lock().unwrap().len(), 4, "each item held once");
        let ids: Vec<&str> = rows.iter().map(|r| r["id"].as_str().unwrap()).collect();
        assert_eq!(
            ids,
            posted.lock().unwrap().iter().map(String::as_str).collect::<Vec<_>>(),
            "held in send order"
        );
        for (n, row) in rows.iter().enumerate() {
            assert_eq!(row["state"], "applied", "{row}");
            assert_eq!(row["seq"].as_u64(), Some(n as u64 + 1));
            let (q, f) = (row["enqueued_unix_ms"].as_u64().unwrap(), row["final_unix_ms"].as_u64().unwrap());
            assert_eq!(row["enqueue_to_final_ms"].as_u64(), Some(f - q));
        }
        let s = summary(&rows);
        assert_eq!(
            (s["applied"].as_u64(), s["seqs_in_order"].as_bool(), s["repeated_seqs"].as_u64()),
            (Some(4), Some(true), Some(0))
        );
        let p50 = s["enqueue_to_applied_ms"]["p50"].as_u64().unwrap();
        let p95 = s["enqueue_to_applied_ms"]["p95"].as_u64().unwrap();
        assert!(p50 >= 1_000 && p95 >= p50, "{s}");
    }
}
