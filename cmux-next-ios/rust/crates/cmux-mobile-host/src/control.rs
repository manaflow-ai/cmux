//! Supervised mode (`CMUX_MOBILE_CONTROL=stdio`): an app (cmux-next) runs cmux-mobile-host
//! as its child and owns sign-in and the acpmux endpoint.
//!
//! stdin carries JSON lines from the app:
//! - `{"type":"token","token":"<Stack access token>"}`: the access token to use
//!   from now on. The app sends one at start and answers every `need_token`
//!   (hostd asks whenever it needs one and its token is under a minute from
//!   expiry, or was refused).
//! - `{"type":"acpmux","url":"ws://127.0.0.1:<port>/","token":"<bearer>"}`:
//!   the app's acpmux WebSocket, sent at start and on `need_acpmux` (it moves
//!   when acpmux restarts).
//! - `{"type":"devices","devices":[{"id","identity_key","approval_key"}],
//!   "denied":[{"id","identity_key"}]}`: the phones the user approved, and those whose request
//!   the user refused (`pairing.rs`). Sent at start and on every change.
//!
//! - `{"type":"mac_identity","private_key":"<hex>","public_key":"<hex>"}`: this
//!   Mac's identity key from the app's Keychain, which `auth` proves to phones
//!   that pinned it (`pairing.rs`). Sent at start; never logged.
//! - `{"type":"drop_phone","phone_device_id":"<uuid>"}`: the owner removed this
//!   phone (Settings > Mobile > Remove): hostd closes its live links now.
//! - `{"type":"phone_credentials","credentials":{"<phone device id>":"<token>"}}`: each
//!   paired phone's own acpmux credential (acpmux pairing role `phone`, which the person
//!   issued through the app), the whole set each time. That phone's `acpmux` channel
//!   presents it instead of the dashboard token, so acpmux knows which phone it is and
//!   that phone's Full-access setting can cover it (`services.rs`). Never logged.
//!
//! End of stdin means the app is gone: the process exits.
//!
//! stdout carries one JSON event per line for the app (logs go to stderr);
//! [`Event`] lists them. Tokens never appear in either stream.

use std::io::Write;
use std::sync::OnceLock;

use serde::{Deserialize, Serialize};
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::sync::{broadcast, watch};

/// The acpmux WebSocket the app reported: URL and bearer token.
pub type AcpmuxEndpoint = Option<(String, Option<String>)>;

static ENABLED: OnceLock<bool> = OnceLock::new();
static DROPS: OnceLock<broadcast::Sender<String>> = OnceLock::new();
static PHONE_CREDENTIALS: std::sync::Mutex<Option<std::collections::HashMap<String, Secret>>> =
    std::sync::Mutex::new(None);

/// The acpmux credential the app gave phone `phone_device_id` (`phone_credentials`), if any.
pub fn phone_credential(phone_device_id: &str) -> Option<String> {
    let credentials = PHONE_CREDENTIALS.lock().unwrap_or_else(|e| e.into_inner());
    credentials.as_ref()?.get(&phone_device_id.to_lowercase()).map(|s| s.0.clone())
}

/// Replaces every phone's acpmux credential (`phone_credentials`); keys are lowercased.
pub fn set_phone_credentials(credentials: std::collections::HashMap<String, Secret>) {
    let lowered = credentials.into_iter().map(|(id, token)| (id.to_lowercase(), token)).collect();
    *PHONE_CREDENTIALS.lock().unwrap_or_else(|e| e.into_inner()) = Some(lowered);
}

/// Phone device ids the app removed, as they arrive (lowercased).
pub fn drops() -> broadcast::Receiver<String> {
    DROPS.get_or_init(|| broadcast::channel(16).0).subscribe()
}

/// Whether this process runs supervised (`CMUX_MOBILE_CONTROL=stdio`).
pub fn enabled() -> bool {
    *ENABLED.get_or_init(|| std::env::var("CMUX_MOBILE_CONTROL").is_ok_and(|v| v.trim() == "stdio"))
}

/// A value that never prints (the Mac's private key).
#[derive(Clone, PartialEq, Eq, Deserialize)]
#[serde(transparent)]
pub struct Secret(pub String);

impl std::fmt::Debug for Secret {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("<redacted>")
    }
}

/// One line from the app.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Inbound {
    Token {
        token: String,
    },
    /// This Mac's identity key from the app's Keychain (`pairing::MacIdentity`):
    /// the raw private scalar and the X9.63 public point, hex. Never logged.
    MacIdentity {
        private_key: Secret,
        public_key: String,
    },
    Acpmux {
        url: String,
        token: Option<String>,
    },
    /// The browser host the app started for `need_browser` `request`: its
    /// loopback rd stream carrier address and per-launch secret.
    Browser {
        request: u64,
        addr: String,
        secret: String,
    },
    /// The app could not start a browser host for `request`.
    BrowserFailed {
        request: u64,
        reason: String,
    },
    /// The browser host of `tab` exited.
    BrowserGone {
        tab: String,
    },
    /// The simulator surface source the app started for `need_surface`
    /// `request` (`surface.rs`): its loopback address and per-launch secret.
    Surface {
        request: u64,
        addr: String,
        secret: String,
    },
    /// The app could not stream the surface of `request` (no such phone tab,
    /// no booted simulator, no live screen with this Xcode).
    SurfaceFailed {
        request: u64,
        reason: String,
    },
    /// The surface source of `tab` ended (its tab closed, its simulator shut down).
    SurfaceGone {
        tab: String,
    },
    Devices(crate::pairing::DeviceTrust),
    DropPhone {
        phone_device_id: String,
    },
    /// Each paired phone's own acpmux credential, by phone device id. Never logged.
    PhoneCredentials {
        credentials: std::collections::HashMap<String, Secret>,
    },
}

impl Inbound {
    /// Parses one stdin line; `None` for anything else (ignored, never echoed).
    pub fn parse(line: &str) -> Option<Self> {
        serde_json::from_str(line.trim()).ok()
    }
}

/// One line to the app.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Event {
    /// Registering and opening the signaling socket.
    Connecting,
    /// Registered and holding the signaling socket: phones can dial.
    Online { device_id: String, team_id: String },
    /// The last attempt failed or the socket closed; retrying after the delay.
    Waiting { reason: String, retry_in_seconds: u64 },
    /// The current access token is missing, about to expire, or was refused.
    NeedToken,
    /// The acpmux endpoint is missing or refused a connection (acpmux restarted).
    NeedAcpmux,
    /// The owner removed this Mac from the account's devices (signaling closed with
    /// 4002 `removed`). hostd exits after this line and must not be restarted until
    /// the person allows iPhone connections again (a new device id then).
    Removed,
    /// A phone's link is up.
    PhoneUp { session_id: String, phone_device_id: String, transport: String, path: String },
    /// A phone's link moved to another path.
    PhonePath { session_id: String, path: String },
    /// A phone's WebRTC media session beside its WireGuard link `session_id`
    /// came up over `media_path` (`direct`, `turn`), or went away (`none`).
    PhoneMedia { session_id: String, media_path: String },
    /// A phone's link ended.
    PhoneDown { session_id: String, reason: String },
    /// A phone proved keys the Mac has not approved: ask the user.
    /// `registered_at_ms` (epoch milliseconds, absent when unknown) is when
    /// that phone device id first registered with the service, for the prompt.
    PairRequest {
        phone_device_id: String,
        name: String,
        identity_key: String,
        approval_key: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        registered_at_ms: Option<i64>,
        /// The pre-approval from the Mac's pairing code the phone presented with its
        /// signature (the app checks and burns it; hostd only forwards it). Absent without one.
        #[serde(skip_serializing_if = "Option::is_none")]
        pair_token: Option<String>,
    },
    /// A paired phone signed out and asks the Mac to forget it.
    Unpaired { phone_device_id: String },
    /// A phone opened browser tab `tab`: start the app's browser host on
    /// `url` and answer with `browser` (or `browser_failed`) for `request`.
    NeedBrowser { request: u64, tab: String, url: String },
    /// hostd no longer needs the browser host of `tab`: stop it.
    BrowserStop { tab: String },
    /// A phone opened simulator surface tab `tab` (`s<surface>`, a phone tab
    /// of this Mac): start its frame source and answer with `surface` (or
    /// `surface_failed`) for `request`.
    NeedSurface { request: u64, tab: String },
    /// hostd no longer needs the surface source of `tab`: stop it.
    SurfaceStop { tab: String },
}

/// Writes `event` as one stdout line when supervised; otherwise nothing.
pub fn emit(event: &Event) {
    if !enabled() {
        return;
    }
    let Ok(line) = serde_json::to_string(event) else { return };
    let mut stdout = std::io::stdout().lock();
    let _ = writeln!(stdout, "{line}");
    let _ = stdout.flush();
}

/// What the app supplies over stdin, as it changes.
#[derive(Clone)]
pub struct Supplied {
    pub token: watch::Receiver<Option<String>>,
    pub acpmux: watch::Receiver<AcpmuxEndpoint>,
    pub devices: watch::Receiver<Option<crate::pairing::DeviceTrust>>,
    /// This Mac's identity key (`mac_identity`), once the app sent it.
    pub identity: watch::Receiver<Option<crate::pairing::MacIdentity>>,
    /// Browser hosts the app starts for the `browser` service.
    pub browser: std::sync::Arc<crate::browser::BrowserBroker>,
    /// Simulator surface sources the app starts for the `surface` service.
    pub surface: std::sync::Arc<crate::browser::BrowserBroker>,
}

/// Reads stdin until it ends, then exits the process (the app is gone).
pub fn spawn_stdin_reader() -> Supplied {
    let (token_tx, token) = watch::channel(None);
    let (acpmux_tx, acpmux) = watch::channel(None);
    let (devices_tx, devices) = watch::channel(None);
    let (identity_tx, identity) = watch::channel(None);
    let browser = std::sync::Arc::new(crate::browser::BrowserBroker::new(std::sync::Arc::new(emit)));
    let broker = std::sync::Arc::clone(&browser);
    let surface = std::sync::Arc::new(crate::browser::BrowserBroker::for_surfaces(std::sync::Arc::new(emit)));
    let surfaces = std::sync::Arc::clone(&surface);
    tokio::spawn(async move {
        let mut lines = BufReader::new(tokio::io::stdin()).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            match Inbound::parse(&line) {
                Some(Inbound::Token { token }) => {
                    token_tx.send_replace(Some(token));
                }
                Some(Inbound::Acpmux { url, token }) => {
                    acpmux_tx.send_replace(Some((url, token)));
                }
                Some(Inbound::MacIdentity { private_key, public_key }) => {
                    match crate::pairing::MacIdentity::from_raw(&private_key.0, &public_key) {
                        Some(key) => {
                            identity_tx.send_replace(Some(key));
                        }
                        None => tracing::warn!("ignoring an unusable Mac identity key"),
                    }
                }
                Some(Inbound::Devices(trust)) => {
                    devices_tx.send_replace(Some(trust));
                }
                Some(Inbound::PhoneCredentials { credentials }) => set_phone_credentials(credentials),
                Some(Inbound::DropPhone { phone_device_id }) => {
                    let _ =
                        DROPS.get_or_init(|| broadcast::channel(16).0).send(phone_device_id.to_lowercase());
                }
                Some(Inbound::Browser { request, addr, secret }) => {
                    broker.answer(request, Ok((addr, secret)));
                }
                Some(Inbound::BrowserFailed { request, reason }) => broker.answer(request, Err(reason)),
                Some(Inbound::BrowserGone { tab }) => broker.gone(&tab),
                Some(Inbound::Surface { request, addr, secret }) => {
                    surfaces.answer(request, Ok((addr, secret)));
                }
                Some(Inbound::SurfaceFailed { request, reason }) => surfaces.answer(request, Err(reason)),
                Some(Inbound::SurfaceGone { tab }) => surfaces.gone(&tab),
                None => tracing::warn!("ignoring an unknown control line"),
            }
        }
        tracing::info!("control input ended; exiting");
        crate::size_release::stop_and_release(crate::size_release::EXIT_WAIT).await;
        std::process::exit(0);
    });
    Supplied { token, acpmux, devices, identity, browser, surface }
}

/// The wire name of a transport.
pub fn transport_name(kind: cmux_mobile_link::TransportKind) -> &'static str {
    match kind {
        cmux_mobile_link::TransportKind::WebRtc => "webrtc",
        cmux_mobile_link::TransportKind::WireGuard => "wireguard",
    }
}

/// The wire name of a path.
pub fn path_name(path: cmux_mobile_link::dial::LinkPath) -> &'static str {
    match path {
        cmux_mobile_link::dial::LinkPath::Direct => "direct",
        cmux_mobile_link::dial::LinkPath::Turn => "turn",
        cmux_mobile_link::dial::LinkPath::TurnTls => "turn-tls",
        cmux_mobile_link::dial::LinkPath::NoPath => "none",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_control_lines() {
        assert_eq!(
            Inbound::parse(r#"{"type":"token","token":"a.b.c"}"#),
            Some(Inbound::Token { token: "a.b.c".into() })
        );
        assert_eq!(
            Inbound::parse(r#"{"type":"acpmux","url":"ws://127.0.0.1:1/","token":"t"}"#),
            Some(Inbound::Acpmux { url: "ws://127.0.0.1:1/".into(), token: Some("t".into()) })
        );
        assert_eq!(
            Inbound::parse(
                r#"{"type":"devices","devices":[{"id":"p","identity_key":"04","approval_key":"04"}],"denied":[{"id":"q","identity_key":"04"}]}"#
            ),
            Some(Inbound::Devices(crate::pairing::DeviceTrust {
                devices: vec![crate::pairing::TrustedDevice {
                    id: "p".into(),
                    identity_key: "04".into(),
                    approval_key: "04".into()
                }],
                denied: vec![crate::pairing::DeniedDevice { id: "q".into(), identity_key: "04".into() }],
            }))
        );
        assert_eq!(
            Inbound::parse(r#"{"type":"drop_phone","phone_device_id":"P"}"#),
            Some(Inbound::DropPhone { phone_device_id: "P".into() })
        );
        assert_eq!(
            Inbound::parse(r#"{"type":"browser","request":3,"addr":"127.0.0.1:5","secret":"s"}"#),
            Some(Inbound::Browser { request: 3, addr: "127.0.0.1:5".into(), secret: "s".into() })
        );
        assert_eq!(
            Inbound::parse(r#"{"type":"browser_gone","tab":"s4"}"#),
            Some(Inbound::BrowserGone { tab: "s4".into() })
        );
        assert_eq!(Inbound::parse(r#"{"type":"nope"}"#), None);
        assert_eq!(Inbound::parse("not json"), None);
    }

    #[test]
    fn phone_credentials_replace_the_set_and_never_print() {
        let Some(Inbound::PhoneCredentials { credentials }) =
            Inbound::parse(r#"{"type":"phone_credentials","credentials":{"AB-1":"tok"}}"#)
        else {
            panic!("a phone_credentials line")
        };
        assert!(!format!("{credentials:?}").contains("tok"));
        set_phone_credentials(credentials);
        assert_eq!(phone_credential("ab-1").as_deref(), Some("tok"));
        assert_eq!(phone_credential("AB-1").as_deref(), Some("tok"));
        set_phone_credentials(Default::default());
        assert_eq!(phone_credential("ab-1"), None, "a phone the app no longer lists has none");
    }

    #[test]
    fn events_are_tagged_json() {
        let line = serde_json::to_string(&Event::PhoneUp {
            session_id: "s".into(),
            phone_device_id: "p".into(),
            transport: "wireguard".into(),
            path: "turn-tls".into(),
        })
        .unwrap();
        assert_eq!(
            line,
            r#"{"type":"phone_up","session_id":"s","phone_device_id":"p","transport":"wireguard","path":"turn-tls"}"#
        );
        assert_eq!(serde_json::to_string(&Event::NeedToken).unwrap(), r#"{"type":"need_token"}"#);
        let request_with = |registered_at_ms, pair_token| Event::PairRequest {
            phone_device_id: "p".into(),
            name: "n".into(),
            identity_key: "04".into(),
            approval_key: "04".into(),
            registered_at_ms,
            pair_token,
        };
        let request = |registered_at_ms| request_with(registered_at_ms, None);
        assert_eq!(
            serde_json::to_string(&request(Some(1_791_961_929_681))).unwrap(),
            r#"{"type":"pair_request","phone_device_id":"p","name":"n","identity_key":"04","approval_key":"04","registered_at_ms":1791961929681}"#
        );
        assert!(!serde_json::to_string(&request(None)).unwrap().contains("registered_at_ms"));
        assert!(!serde_json::to_string(&request(None)).unwrap().contains("pair_token"));
        let scanned = request_with(None, Some("AbC-dEf_0123456789".into()));
        assert_eq!(
            serde_json::to_string(&scanned).unwrap(),
            r#"{"type":"pair_request","phone_device_id":"p","name":"n","identity_key":"04","approval_key":"04","pair_token":"AbC-dEf_0123456789"}"#
        );
        assert_eq!(serde_json::to_string(&Event::Removed).unwrap(), r#"{"type":"removed"}"#);
        assert_eq!(
            serde_json::to_string(&Event::NeedBrowser {
                request: 1,
                tab: "s4".into(),
                url: "about:blank".into()
            })
            .unwrap(),
            r#"{"type":"need_browser","request":1,"tab":"s4","url":"about:blank"}"#
        );
        assert_eq!(
            serde_json::to_string(&Event::Waiting { reason: "x".into(), retry_in_seconds: 2 }).unwrap(),
            r#"{"type":"waiting","reason":"x","retry_in_seconds":2}"#
        );
    }
}
