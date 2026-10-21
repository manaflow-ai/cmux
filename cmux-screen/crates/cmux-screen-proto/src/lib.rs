//! Wire formats shared by every cmux screen stream host and viewer.
//!
//! These match the Swift implementation (`Packages/Shared/CmuxVNCWebRTC`)
//! byte for byte, so the existing iOS app pairs with a Rust host unchanged:
//!
//! - a pairing link `cmux-vnc://pair?signal=…&room=…&secret=…&name=…&kind=…`;
//! - room signaling messages relayed by the signal Worker;
//! - input (`ScreenInput`) on the `input` (ordered) and `pointer`
//!   (unordered) data channels, and `ScreenHostMessage` back to the viewer;
//! - the viewer's quality choice and how a host turns it into WebRTC sender
//!   parameters.

mod pairing;
mod quality;

pub use pairing::{Pairing, PairingError, DEFAULT_SIGNAL, SECRET_HEADER};
pub use quality::{Degradation, Quality, QualitySettings};

use serde::{Deserialize, Serialize};

/// Data channel the viewer opens for ordered input and host messages.
pub const INPUT_CHANNEL: &str = "input";
/// Data channel for pointer moves with no button change (unordered, no retransmits: latest wins).
pub const POINTER_CHANNEL: &str = "pointer";
/// Stream id and track id of the screen video track.
pub const SCREEN_TRACK: &str = "screen";

/// One message relayed by the room between host and viewer.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct SignalMessage {
    /// hello, peer-joined, peer-left, offer, answer, candidate.
    #[serde(rename = "type")]
    pub kind: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sdp: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub candidate: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sdp_mid: Option<String>,
    #[serde(default, rename = "sdpMLineIndex", skip_serializing_if = "Option::is_none")]
    pub sdp_mline_index: Option<i32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub role: Option<String>,
    /// In `hello`: whether the other role is already in the room.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub peer: Option<bool>,
}

impl SignalMessage {
    pub fn new(kind: &str) -> Self {
        Self { kind: kind.to_owned(), ..Self::default() }
    }

    pub fn with_sdp(kind: &str, sdp: String) -> Self {
        Self { kind: kind.to_owned(), sdp: Some(sdp), ..Self::default() }
    }
}

/// Viewer → host input and control. Pointer coordinates are normalized
/// (0…1) within the display being streamed.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct ScreenInput {
    /// move, scroll, key, chord, text, display, refresh, quality.
    pub t: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub x: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub y: Option<f64>,
    /// Button mask (1 left, 2 middle, 4 right).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub b: Option<u8>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dx: Option<i32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dy: Option<i32>,
    /// X11 keysym.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub k: Option<u32>,
    /// Key down (true) or up.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub d: Option<bool>,
    /// Text to type, or the quality name.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub s: Option<String>,
    /// Display index.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub i: Option<usize>,
    /// Modifier keysyms for `chord`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub m: Option<Vec<u32>>,
}

/// What a viewer asks for, decoded from a `ScreenInput`.
#[derive(Debug, Clone, PartialEq)]
pub enum Input {
    /// Pointer at (x, y) with `buttons` held; a change in buttons is a press or release.
    Pointer { x: f64, y: f64, buttons: u8 },
    Scroll { x: f64, y: f64, dx: i32, dy: i32 },
    Key { keysym: u32, down: bool },
    /// Modifiers down, key down and up, modifiers up (in reverse).
    Chord { modifiers: Vec<u32>, keysym: u32 },
    Text(String),
    SelectDisplay(usize),
    Quality(Quality),
    Refresh,
}

impl ScreenInput {
    /// The request, or None for a malformed or unknown message (ignored, as the Swift host does).
    pub fn decode(&self) -> Option<Input> {
        let at = || (self.x.unwrap_or(0.0).clamp(0.0, 1.0), self.y.unwrap_or(0.0).clamp(0.0, 1.0));
        Some(match self.t.as_str() {
            "move" => {
                let (x, y) = at();
                Input::Pointer { x, y, buttons: self.b.unwrap_or(0) }
            }
            "scroll" => {
                let (x, y) = at();
                Input::Scroll { x, y, dx: self.dx.unwrap_or(0), dy: self.dy.unwrap_or(0) }
            }
            "key" => Input::Key { keysym: self.k?, down: self.d.unwrap_or(true) },
            "chord" => Input::Chord { modifiers: self.m.clone().unwrap_or_default(), keysym: self.k? },
            "text" => Input::Text(self.s.clone()?),
            "display" => Input::SelectDisplay(self.i?),
            "quality" => Input::Quality(self.s.as_deref()?.parse().ok()?),
            "refresh" => Input::Refresh,
            _ => return None,
        })
    }
}

/// Host → viewer: the displays (pixel sizes) and which one is streaming.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ScreenHostMessage {
    pub t: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub displays: Option<Vec<DisplaySize>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub current: Option<usize>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct DisplaySize {
    pub w: u32,
    pub h: u32,
}

impl ScreenHostMessage {
    pub fn displays(sizes: &[DisplaySize], current: usize, name: &str) -> Self {
        Self { t: "displays".into(), displays: Some(sizes.to_vec()), current: Some(current), name: Some(name.into()) }
    }
}

/// The signal Worker's ICE server list (`GET /v1/rooms/<room>/ice`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct IceAnswer {
    pub ice_servers: Vec<IceServer>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct IceServer {
    pub urls: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub username: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub credential: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn signal_messages_match_the_swift_field_names() {
        let candidate = SignalMessage {
            kind: "candidate".into(),
            candidate: Some("candidate:1 1 udp 1 1.2.3.4 5 typ host".into()),
            sdp_mid: Some("0".into()),
            sdp_mline_index: Some(0),
            ..SignalMessage::default()
        };
        let json = serde_json::to_value(&candidate).unwrap();
        assert_eq!(json["type"], "candidate");
        assert_eq!(json["sdpMid"], "0");
        assert_eq!(json["sdpMLineIndex"], 0);
        assert!(json.get("sdp").is_none(), "absent fields are omitted, as Swift's JSONEncoder does");

        let hello: SignalMessage = serde_json::from_str(r#"{"type":"hello","role":"viewer","peer":true}"#).unwrap();
        assert_eq!(hello.kind, "hello");
        assert_eq!(hello.peer, Some(true));
    }

    #[test]
    fn input_messages_from_the_ios_app_decode() {
        let cases: &[(&str, Input)] = &[
            (r#"{"t":"move","x":0.25,"y":0.5,"b":1}"#, Input::Pointer { x: 0.25, y: 0.5, buttons: 1 }),
            (r#"{"t":"scroll","x":0.5,"y":0.5,"dx":0,"dy":-3}"#, Input::Scroll { x: 0.5, y: 0.5, dx: 0, dy: -3 }),
            (r#"{"t":"key","k":65293,"d":false}"#, Input::Key { keysym: 0xFF0D, down: false }),
            (r#"{"t":"chord","k":32,"m":[65511]}"#, Input::Chord { modifiers: vec![0xFFE7], keysym: 0x20 }),
            (r#"{"t":"text","s":"héllo"}"#, Input::Text("héllo".into())),
            (r#"{"t":"display","i":1}"#, Input::SelectDisplay(1)),
            (r#"{"t":"quality","s":"low"}"#, Input::Quality(Quality::Low)),
            (r#"{"t":"refresh"}"#, Input::Refresh),
        ];
        for (json, expected) in cases {
            let input: ScreenInput = serde_json::from_str(json).unwrap();
            assert_eq!(input.decode().as_ref(), Some(expected), "{json}");
        }
    }

    #[test]
    fn malformed_input_is_ignored() {
        for json in [r#"{"t":"key"}"#, r#"{"t":"quality","s":"ultra"}"#, r#"{"t":"teleport"}"#, r#"{"t":"display"}"#] {
            let input: ScreenInput = serde_json::from_str(json).unwrap();
            assert_eq!(input.decode(), None, "{json}");
        }
    }

    #[test]
    fn pointer_coordinates_stay_on_the_display() {
        let input: ScreenInput = serde_json::from_str(r#"{"t":"move","x":-2,"y":7}"#).unwrap();
        assert_eq!(input.decode(), Some(Input::Pointer { x: 0.0, y: 1.0, buttons: 0 }));
    }

    #[test]
    fn display_message_matches_what_the_viewer_reads() {
        let message = ScreenHostMessage::displays(&[DisplaySize { w: 1920, h: 1080 }], 0, "Mac mini 2");
        assert_eq!(
            serde_json::to_string(&message).unwrap(),
            r#"{"t":"displays","displays":[{"w":1920,"h":1080}],"current":0,"name":"Mac mini 2"}"#
        );
    }

    #[test]
    fn ice_answer_decodes() {
        let answer: IceAnswer = serde_json::from_str(
            r#"{"iceServers":[{"urls":["stun:stun.cloudflare.com:3478"]},{"urls":["turn:x:3478?transport=udp"],"username":"u","credential":"c"}]}"#,
        )
        .unwrap();
        assert_eq!(answer.ice_servers.len(), 2);
        assert_eq!(answer.ice_servers[1].username.as_deref(), Some("u"));
    }
}
