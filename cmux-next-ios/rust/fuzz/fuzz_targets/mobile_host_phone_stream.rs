//! cmux-mobile-host's rd stream relay (`browser.rs` `splice`, `surface.rs`):
//! the bytes a phone sends on a `browser` or `surface` channel, read the way
//! hostd reads them (an rd `StreamDeframer`, fed in the input's own chunk
//! sizes), each whole frame through the channel's `filter_frame`, the
//! `rb.visibility` reader and the track-mode datagram check; and the bytes a
//! browser host sends back, through its deframer and the page guard's
//! `rb.page` reader. Every JSON value the phone sends also goes through the
//! surface's `input_line`, as an rd `service` input event would.
//!
//! Invariants past "no panic":
//! - the filters forward only control and datagram frames, a phone's
//!   `hello` never, and both filters agree on what they refuse;
//! - `Navigate` comes only from an `rb.navigate` control frame, with its URL;
//! - a forwarded frame encodes again (hostd re-frames what it forwards);
//! - an input line is one of the surface's own messages, with coordinates
//!   in 0..=1.
#![no_main]

use cmux_mobile_host::browser::{self, FrameVerdict};
use cmux_mobile_host::{browser_track, surface};
use cmux_rd_proto::{STREAM_CONTROL, STREAM_DATAGRAM, StreamDeframer, encode_stream_frame};
use libfuzzer_sys::fuzz_target;
use serde_json::Value;

/// The most frames one direction of one input reads.
const MAX_FRAMES: usize = 256;

/// Splits `data` into chunks whose sizes the input picks: a length byte,
/// then that many bytes (0 takes the rest).
fn chunks(mut data: &[u8]) -> Vec<&[u8]> {
    let mut out = Vec::new();
    while let Some((&len, rest)) = data.split_first() {
        let len = if len == 0 { rest.len() } else { usize::from(len).min(rest.len()) };
        let (chunk, rest) = rest.split_at(len);
        out.push(chunk);
        data = rest;
    }
    out
}

fn frames(data: &[u8]) -> Vec<(u8, Vec<u8>)> {
    let mut deframer = StreamDeframer::default();
    let mut out = Vec::new();
    for chunk in chunks(data) {
        deframer.extend(chunk);
        loop {
            match deframer.next_frame() {
                Ok(Some(frame)) if out.len() < MAX_FRAMES => out.push(frame),
                Ok(Some(_)) | Ok(None) => break,
                // hostd closes the channel on a bad stream; so does a broken
                // deframer: it keeps answering the error.
                Err(_) => {
                    assert!(deframer.next_frame().is_err(), "a failed deframer recovered");
                    return out;
                }
            }
        }
    }
    out
}

fn control(payload: &[u8]) -> Option<Value> {
    serde_json::from_slice(payload).ok()
}

/// `input_line` on a phone input event: the JSON of an rd `service` input,
/// any JSON the phone sends. Twice, so a `down` meets its `move` and `up`.
fn check_input(event: &Value) {
    let mut touching = false;
    for _ in 0..2 {
        let Some(line) = surface::input_line(event, &mut touching) else { continue };
        let t = line.get("t").and_then(Value::as_str);
        assert!(
            matches!(t, Some("touch" | "text" | "key" | "button")),
            "an input line the surface does not speak: {line}"
        );
        for axis in ["x", "y"] {
            if let Some(v) = line.get(axis) {
                let v = v.as_f64().expect("a numeric coordinate");
                assert!((0.0..=1.0).contains(&v), "{axis} out of the unit range: {line}");
            }
        }
    }
}

fn check_phone_frame(kind: u8, payload: &[u8]) {
    let browser_verdict = browser::filter_frame(kind, payload);
    let surface_verdict = surface::filter_frame(kind, payload);
    let forwarded = |verdict: &FrameVerdict| !matches!(verdict, FrameVerdict::Drop(_));
    for verdict in [&browser_verdict, &surface_verdict] {
        if forwarded(verdict) {
            assert!(
                kind == STREAM_CONTROL || kind == STREAM_DATAGRAM,
                "a frame of kind {kind} was forwarded"
            );
            let mut out = Vec::new();
            assert!(
                encode_stream_frame(kind, payload, &mut out).is_ok(),
                "a forwarded frame does not encode"
            );
        }
    }
    let message = control(payload);
    let t = message.as_ref().and_then(|m| m.get("t")).and_then(Value::as_str);
    if kind == STREAM_CONTROL && t == Some("hello") {
        assert!(
            !forwarded(&browser_verdict) && !forwarded(&surface_verdict),
            "a phone's hello was forwarded"
        );
    }
    // A surface viewer may send a subset of what a browser viewer may.
    if forwarded(&surface_verdict) {
        assert!(forwarded(&browser_verdict), "the surface forwarded a frame the browser drops");
    }
    if let FrameVerdict::Navigate(url) = &browser_verdict {
        assert_eq!(kind, STREAM_CONTROL, "a navigation from a non-control frame");
        let body = message.as_ref().and_then(|m| m.get("body")).expect("an rb body");
        assert_eq!(body.get("t").and_then(Value::as_str), Some("rb.navigate"));
        assert_eq!(body.get("url").and_then(Value::as_str), Some(url.as_str()));
    }
    if kind == STREAM_CONTROL {
        if let Some(shown) = browser::visibility(payload) {
            let body = message.as_ref().and_then(|m| m.get("body")).expect("an rb body");
            assert_eq!(body.get("visible").and_then(Value::as_bool), Some(shown));
        }
        if let Some(message) = &message {
            check_input(message);
            if let Some(body) = message.get("body") {
                check_input(body);
            }
        }
    } else {
        let _ = browser_track::phone_datagram_superseded(payload);
    }
}

fuzz_target!(|data: &[u8]| {
    // A u16 LE length, then that many bytes the phone sends; the rest the host sends.
    let Some((length, rest)) = data.split_first_chunk::<2>() else { return };
    let at = usize::from(u16::from_le_bytes(*length)).min(rest.len());
    let (phone, host) = rest.split_at(at);
    for (kind, payload) in frames(phone) {
        check_phone_frame(kind, &payload);
    }
    for (kind, payload) in frames(host) {
        if kind == STREAM_CONTROL
            && let Some((url, _)) = browser::page_url(&payload)
        {
            let body = control(&payload).and_then(|m| m.get("body").cloned()).expect("an rb.page body");
            assert_eq!(body.get("url").and_then(Value::as_str), Some(url.as_str()));
        }
    }
});
