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
//!            --session SESSION_ID [--text T] [--count N] [--wait SECS]
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
//! Prints one JSON line per item: its id, the hub's seq, the final state and
//! the milliseconds from the first post to that state.

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

/// Posts every item in order (each post answered before the next, so the hub's
/// seqs follow send order), then polls them all until each is final or `--wait` ends.
pub async fn run(args: &Args) -> Result<Vec<Value>> {
    let http = cmux_mobile_link::api::ApiClient::http_client();
    let started = Instant::now();
    let deadline = started + args.wait;
    let mut trackers: Vec<(Tracker, Option<Duration>)> = items(args, unix_ms() / 1000)?
        .into_iter()
        .map(|item| (Tracker::new(item, None, false, unix_ms()), None))
        .collect();
    // The posts, in order: a tracker that cannot post yet waits its turn, so a
    // later item never reaches the hub first.
    for (tracker, _) in trackers.iter_mut() {
        while matches!(tracker.state(), State::Posting) && Instant::now() < deadline {
            match tracker.next(unix_ms()) {
                Step::Send(request @ Request::Post { .. }) => match send(&http, args, &request).await {
                    Ok((status, body)) => tracker.on_post(status, &body, unix_ms()),
                    Err(_) => tracker.on_transport_error(unix_ms()),
                },
                Step::Wait { until_ms } => {
                    tokio::time::sleep(Duration::from_millis(until_ms.saturating_sub(unix_ms()).min(1_000)))
                        .await;
                }
                Step::Send(Request::Poll { .. }) | Step::Done => break,
            }
        }
    }
    while Instant::now() < deadline {
        let mut soonest: Option<u64> = None;
        for (tracker, settled) in trackers.iter_mut() {
            if settled.is_some() {
                continue;
            }
            match tracker.next(unix_ms()) {
                Step::Send(request) => {
                    let answer = send(&http, args, &request).await;
                    match (&request, answer) {
                        (Request::Post { .. }, Ok((status, body))) => {
                            tracker.on_post(status, &body, unix_ms());
                        }
                        (Request::Poll { .. }, Ok((status, body))) => {
                            tracker.on_poll(status, &body, unix_ms());
                        }
                        (_, Err(_)) => tracker.on_transport_error(unix_ms()),
                    }
                    soonest = Some(unix_ms());
                }
                Step::Wait { until_ms } => soonest = Some(soonest.map_or(until_ms, |s| s.min(until_ms))),
                Step::Done => {}
            }
            if tracker.state().is_final() {
                *settled = Some(started.elapsed());
            }
        }
        let Some(until) = soonest else { break };
        tokio::time::sleep(Duration::from_millis(until.saturating_sub(unix_ms()).min(1_000))).await;
    }
    Ok(trackers
        .iter()
        .map(|(tracker, settled)| {
            json!({
                "id": tracker.id(),
                "seq": tracker.seq(),
                "state": state_name(tracker.state()),
                "final": tracker.state().is_final(),
                "post_to_final_ms": settled.map(|d| d.as_millis() as u64),
            })
        })
        .collect())
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
    for result in results {
        println!("{result}");
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
}
