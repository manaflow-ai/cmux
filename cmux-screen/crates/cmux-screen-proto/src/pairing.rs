use std::fmt;

use base64::Engine;
use serde::{Deserialize, Serialize};
use url::Url;

/// The cmux screen signal Worker (Cloudflare Worker + Durable Object room).
pub const DEFAULT_SIGNAL: &str = "https://cmux-vnc-signal.debussy.workers.dev";

/// What a viewer needs to reach a host: the signal Worker, the room, and
/// the room secret. Saved as JSON (`pairing.json`) in the same shape as the
/// Swift host, so either host can serve a room the phone already knows.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Pairing {
    pub signal: String,
    pub room: String,
    pub secret: String,
    pub name: String,
    /// `stream` (screen as WebRTC video) or `vnc` (RFB bytes over a data channel).
    #[serde(default = "default_kind")]
    pub kind: String,
}

fn default_kind() -> String {
    "vnc".into()
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PairingError {
    NotAPairingLink,
    Missing(&'static str),
    Invalid(&'static str),
    Random,
}

impl fmt::Display for PairingError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NotAPairingLink => write!(f, "not a cmux-vnc://pair link"),
            Self::Missing(field) => write!(f, "pairing link has no {field}"),
            Self::Invalid(field) => write!(f, "pairing link has an invalid {field}"),
            Self::Random => write!(f, "no system randomness"),
        }
    }
}

impl std::error::Error for PairingError {}

impl Pairing {
    /// A new room (128-bit id, hex) and secret (256-bit, base64url) on `signal`.
    pub fn generate(name: &str, signal: &str, kind: &str) -> Result<Self, PairingError> {
        let mut room = [0u8; 16];
        let mut secret = [0u8; 32];
        getrandom::getrandom(&mut room).map_err(|_| PairingError::Random)?;
        getrandom::getrandom(&mut secret).map_err(|_| PairingError::Random)?;
        Ok(Self {
            signal: signal.to_owned(),
            room: room.iter().map(|b| format!("{b:02x}")).collect(),
            secret: base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(secret),
            name: name.to_owned(),
            kind: kind.to_owned(),
        })
    }

    pub fn is_stream(&self) -> bool {
        self.kind == "stream"
    }

    /// `cmux-vnc://pair?signal=…&room=…&secret=…&name=…&kind=…`, with
    /// spaces as `%20`: the Swift viewer reads a query with URLComponents,
    /// which keeps `+` literal.
    pub fn link(&self) -> String {
        let fields = [
            ("signal", &self.signal),
            ("room", &self.room),
            ("secret", &self.secret),
            ("name", &self.name),
            ("kind", &self.kind),
        ];
        let query: Vec<String> = fields.iter().map(|(key, value)| format!("{key}={}", percent_encode(value))).collect();
        format!("cmux-vnc://pair?{}", query.join("&"))
    }

    /// Parses a pairing link with the Swift viewer's checks: an https
    /// signal URL, a 32-hex-digit room and a 32-128 character secret.
    pub fn from_link(link: &str) -> Result<Self, PairingError> {
        let url = Url::parse(link).map_err(|_| PairingError::NotAPairingLink)?;
        if url.scheme() != "cmux-vnc" || url.host_str() != Some("pair") {
            return Err(PairingError::NotAPairingLink);
        }
        // Percent-decoding only: `+` stays literal, as Swift's URLComponents reads it.
        let query = url.query().unwrap_or("");
        let value = |name: &str| {
            query.split('&').find_map(|pair| {
                let (key, value) = pair.split_once('=')?;
                (key == name).then(|| percent_encoding::percent_decode_str(value).decode_utf8_lossy().into_owned())
            })
        };
        let signal = value("signal").ok_or(PairingError::Missing("signal"))?;
        if Url::parse(&signal).map(|u| u.scheme() != "https").unwrap_or(true) {
            return Err(PairingError::Invalid("signal"));
        }
        let room = value("room").ok_or(PairingError::Missing("room"))?;
        if room.len() != 32 || !room.chars().all(|c| c.is_ascii_hexdigit()) {
            return Err(PairingError::Invalid("room"));
        }
        let secret = value("secret").ok_or(PairingError::Missing("secret"))?;
        if !(32..=128).contains(&secret.chars().count()) {
            return Err(PairingError::Invalid("secret"));
        }
        let kind = if value("kind").as_deref() == Some("stream") { "stream" } else { "vnc" };
        Ok(Self { signal, room, secret, name: value("name").unwrap_or_else(|| "Mac".into()), kind: kind.into() })
    }

    /// `<signal>/v1/rooms/<room>/<path>`, with `role` as a query for the WebSocket.
    pub fn room_url(&self, path: &str, role: Option<&str>) -> String {
        let mut url = format!("{}/v1/rooms/{}/{}", self.signal.trim_end_matches('/'), self.room, path);
        if let Some(role) = role {
            url.push_str("?role=");
            url.push_str(role);
        }
        url
    }

    /// The room WebSocket URL (`wss://…`) for `role`.
    pub fn socket_url(&self, role: &str) -> String {
        let url = self.room_url("ws", Some(role));
        url.strip_prefix("https://").map(|rest| format!("wss://{rest}")).unwrap_or(url)
    }
}

/// Percent-encodes everything but RFC 3986 unreserved characters and `:/`.
fn percent_encode(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for byte in value.bytes() {
        if byte.is_ascii_alphanumeric() || b"-._~:/".contains(&byte) {
            out.push(byte as char);
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
}

/// Header carrying the room secret on every room request.
pub const SECRET_HEADER: &str = "x-room-secret";

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_generated_pairing_round_trips_through_its_link() {
        let pairing = Pairing::generate("Mac mini 2", DEFAULT_SIGNAL, "stream").unwrap();
        assert_eq!(pairing.room.len(), 32);
        assert_eq!(pairing.secret.len(), 43);
        assert_eq!(Pairing::from_link(&pairing.link()).unwrap(), pairing);
    }

    #[test]
    fn a_link_from_the_swift_host_parses() {
        let link = "cmux-vnc://pair?signal=https://cmux-vnc-signal.debussy.workers.dev&room=c4bda70eee2eef46caac272224acf670&secret=8FEGu28vwJSbnNg9GfeP8c7yoZMlSbfEfL55NurITx8&name=Mac%20mini%202&kind=stream";
        let pairing = Pairing::from_link(link).unwrap();
        assert_eq!(pairing.name, "Mac mini 2");
        assert!(pairing.is_stream());
        assert_eq!(
            pairing.socket_url("host"),
            "wss://cmux-vnc-signal.debussy.workers.dev/v1/rooms/c4bda70eee2eef46caac272224acf670/ws?role=host"
        );
    }

    #[test]
    fn spaces_in_the_name_survive_a_reader_that_keeps_plus_literal() {
        let pairing = Pairing::generate("Mac mini 2 (Rust)", DEFAULT_SIGNAL, "stream").unwrap();
        let link = pairing.link();
        assert!(link.contains("name=Mac%20mini%202%20%28Rust%29"), "{link}");
        assert!(link.contains("signal=https://cmux-vnc-signal.debussy.workers.dev&"), "{link}");
        assert_eq!(Pairing::from_link(&link).unwrap().name, "Mac mini 2 (Rust)");
    }

    #[test]
    fn a_plus_in_the_name_stays_a_plus() {
        let pairing = Pairing::generate("C++ box", DEFAULT_SIGNAL, "stream").unwrap();
        assert_eq!(Pairing::from_link(&pairing.link()).unwrap().name, "C++ box");
        let typed = pairing.link().replace("C%2B%2B%20box", "C++%20box");
        assert_eq!(Pairing::from_link(&typed).unwrap().name, "C++ box", "a literal + is not a space");
    }

    #[test]
    fn the_swift_pairing_file_decodes() {
        let json = r#"{"signal":"https:\/\/cmux-vnc-signal.debussy.workers.dev","room":"c4bda70eee2eef46caac272224acf670","secret":"8FEGu28vwJSbnNg9GfeP8c7yoZMlSbfEfL55NurITx8","name":"Mac mini 2","kind":"stream"}"#;
        let pairing: Pairing = serde_json::from_str(json).unwrap();
        assert_eq!(pairing.signal, DEFAULT_SIGNAL);
        let old: Pairing = serde_json::from_str(r#"{"signal":"https://x.dev","room":"00","secret":"s","name":"n"}"#).unwrap();
        assert_eq!(old.kind, "vnc", "files from before `kind` mean an RFB pairing");
    }

    #[test]
    fn bad_links_are_refused() {
        let good = Pairing::generate("m", DEFAULT_SIGNAL, "stream").unwrap();
        let cases = [
            ("https://pair?room=x", PairingError::NotAPairingLink),
            (&good.link().replace("signal=https:", "signal=http:"), PairingError::Invalid("signal")),
            (&good.link().replace(&good.room, "zz"), PairingError::Invalid("room")),
            (&good.link().replace(&good.secret, "short"), PairingError::Invalid("secret")),
        ];
        for (link, error) in cases {
            assert_eq!(Pairing::from_link(link), Err(error), "{link}");
        }
    }
}
