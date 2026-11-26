//! The fake backend's relay cache (`FakeOptions::relay_cache`): a Rust mirror of the Worker's
//! `/v1/relay-cache/<source>/(snapshot|delta|catch-up|ack)` (backend `src/relay-cache.ts`), so the
//! phone client, the Mac publisher and the harness rows run in one process. One newest snapshot per
//! (source, viewer, stream) and one [`DeltaLog`] per slot, with the Worker's bounds and answers. It
//! does not check device kinds or owners (the Worker's miniflare tests cover those): a write must
//! come from the source itself and name a viewer, a read is the caller's own slot.

use std::collections::HashMap;

use base64::Engine as _;
use cmux_relay_snapshot::delta::{CatchUp, DeltaLog};
use cmux_relay_snapshot::{Error, Position, peek};
use serde_json::{Value, json};

use crate::relay_cache::{DEFAULT_BUDGET_BYTES, MAX_BUDGET_BYTES, MAX_SURFACES, WirePosition};

/// The seal's plaintext bound plus the envelope's fixed bytes (relay-cache.ts `ENVELOPE_MAX`).
const ENVELOPE_MAX: usize = cmux_relay_snapshot::MAX_PLAINTEXT + 1 + 8 + 8 + 32 + 65 + 12 + 4 + 16 + 64;

type Slot = (String, String, String);

#[derive(Default)]
pub(super) struct FakeRelayCache {
    snapshots: HashMap<Slot, (Vec<u8>, u64)>,
    logs: HashMap<Slot, DeltaLog>,
    /// Requests answered, by route (`snapshot GET`, `catch-up`, ...).
    pub(super) hits: HashMap<&'static str, u64>,
}

/// What a relay cache request gets back: status line, content type, body, extra headers.
pub(super) struct Answer {
    pub status: &'static str,
    pub content_type: &'static str,
    pub body: Vec<u8>,
    pub headers: Vec<(String, String)>,
}

fn json_answer(status: &'static str, value: &Value) -> Answer {
    Answer {
        status,
        content_type: "application/json",
        body: value.to_string().into_bytes(),
        headers: Vec::new(),
    }
}

fn refuse(status: &'static str, code: &str) -> Answer {
    json_answer(status, &json!({"error": {"code": code}}))
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%'
            && let Some(hex) = bytes.get(i + 1..i + 3).and_then(|h| std::str::from_utf8(h).ok())
            && let Ok(byte) = u8::from_str_radix(hex, 16)
        {
            out.push(byte);
            i += 3;
            continue;
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn valid_stream(s: &str) -> bool {
    (1..=96).contains(&s.len()) && s.bytes().all(|b| b.is_ascii_alphanumeric() || b"._/-".contains(&b))
}

impl FakeRelayCache {
    /// Answers `method target` (`/v1/relay-cache/...?...`) with `body`; `on` is the Worker's switch.
    pub(super) fn answer(&mut self, method: &str, target: &str, body: &[u8], on: bool) -> Answer {
        if !on {
            return refuse("503 Service Unavailable", "relay_cache_off");
        }
        let (path, query) = target.split_once('?').unwrap_or((target, ""));
        let params: HashMap<String, String> = query
            .split('&')
            .filter_map(|kv| kv.split_once('='))
            .map(|(k, v)| (k.to_owned(), decode(v)))
            .collect();
        let mut parts = path.trim_start_matches("/v1/relay-cache/").split('/');
        let (Some(source), Some(what), None) = (parts.next(), parts.next(), parts.next()) else {
            return refuse("404 Not Found", "not_found");
        };
        let source = source.to_ascii_lowercase();
        let device = params.get("deviceId").map(|d| d.to_ascii_lowercase()).unwrap_or_default();
        if device.is_empty() {
            return refuse("400 Bad Request", "bad_request");
        }
        let writes = (what == "snapshot" && method == "PUT") || (what == "delta" && method == "POST");
        let viewer = if writes {
            if device != source {
                return refuse("403 Forbidden", "not_the_source");
            }
            match params.get("viewer") {
                Some(v) if !v.is_empty() => v.to_ascii_lowercase(),
                _ => return refuse("400 Bad Request", "bad_request"),
            }
        } else {
            device
        };
        let now = now_ms();
        if what == "catch-up" && method == "POST" {
            *self.hits.entry("catch-up").or_default() += 1;
            return self.catch_up(&source, &viewer, body, now);
        }
        let stream = params.get("stream").cloned().unwrap_or_default();
        if !valid_stream(&stream) {
            return refuse("400 Bad Request", "bad_stream");
        }
        let slot = (source, viewer, stream);
        match (what, method) {
            ("snapshot", "PUT") => {
                *self.hits.entry("snapshot PUT").or_default() += 1;
                if body.len() > ENVELOPE_MAX {
                    return refuse("413 Payload Too Large", "too_large");
                }
                let Ok(header) = peek(body) else { return refuse("400 Bad Request", "malformed") };
                let stale =
                    self.snapshots.get(&slot).and_then(|(held, _)| peek(held).ok()).is_some_and(|held| {
                        held.source_key_id == header.source_key_id && header.position <= held.position
                    });
                if !stale {
                    self.snapshots.insert(slot, (body.to_vec(), now));
                }
                json_answer("200 OK", &json!({"ok": true, "outcome": if stale { "stale" } else { "stored" }}))
            }
            ("snapshot", "GET") => {
                *self.hits.entry("snapshot GET").or_default() += 1;
                match self.snapshots.get(&slot) {
                    Some((envelope, at)) => Answer {
                        status: "200 OK",
                        content_type: "application/octet-stream",
                        body: envelope.clone(),
                        headers: vec![("x-cmux-cache-at".into(), at.to_string())],
                    },
                    None => refuse("404 Not Found", "no_snapshot"),
                }
            }
            ("delta", "POST") => {
                *self.hits.entry("delta POST").or_default() += 1;
                if body.len() > ENVELOPE_MAX {
                    return refuse("413 Payload Too Large", "too_large");
                }
                match self.logs.entry(slot).or_default().append(body.to_vec(), now) {
                    Ok(outcome) => {
                        json_answer("200 OK", &json!({"ok": true, "outcome": format!("{outcome:?}")}))
                    }
                    Err(Error::WrongSource) => refuse("409 Conflict", "wrong_source"),
                    Err(_) => refuse("400 Bad Request", "malformed"),
                }
            }
            ("ack", "POST") => {
                *self.hits.entry("ack").or_default() += 1;
                let Some(through) = serde_json::from_slice::<Value>(body)
                    .ok()
                    .and_then(|v| serde_json::from_value::<WirePosition>(v.get("through")?.clone()).ok())
                else {
                    return refuse("400 Bad Request", "bad_request");
                };
                let drained = self.logs.get_mut(&slot).map_or(0, |log| {
                    let before = log.len();
                    log.drain_through(through.0);
                    before - log.len()
                });
                json_answer("200 OK", &json!({"drained": drained}))
            }
            _ => refuse("404 Not Found", "not_found"),
        }
    }

    /// relay-cache.ts `catchUpMany`.
    fn catch_up(&mut self, source: &str, viewer: &str, body: &[u8], now: u64) -> Answer {
        let Ok(request) = serde_json::from_slice::<Value>(body) else {
            return refuse("400 Bad Request", "bad_request");
        };
        let Some(asks) =
            request.get("surfaces").and_then(Value::as_array).filter(|a| a.len() <= MAX_SURFACES)
        else {
            return refuse("400 Bad Request", "bad_request");
        };
        let budget = request
            .get("budgetBytes")
            .and_then(Value::as_u64)
            .map_or(DEFAULT_BUDGET_BYTES, |b| (b as usize).min(MAX_BUDGET_BYTES));
        let mut left = budget;
        let mut surfaces = Vec::new();
        let mut cut = Vec::new();
        for ask in asks {
            let surface = ask.get("surface").and_then(Value::as_str).unwrap_or_default().to_owned();
            let after =
                ask.get("after").cloned().and_then(|a| serde_json::from_value::<WirePosition>(a).ok());
            let (true, Some(WirePosition(after))) = (valid_stream(&surface), after) else {
                return refuse("400 Bad Request", "bad_request");
            };
            let slot = (source.to_owned(), viewer.to_owned(), surface.clone());
            let got = self.logs.get_mut(&slot).map_or(CatchUp::Gap, |log| log.catch_up(after, now));
            let CatchUp::Deltas(envelopes) = got else {
                cut.push(surface);
                continue;
            };
            let size: usize = envelopes.iter().map(Vec::len).sum();
            if size > left {
                cut.push(surface);
                continue;
            }
            left -= size;
            let head: Position = envelopes.last().and_then(|e| peek(e).ok()).map_or(after, |h| h.position);
            let sealed: Vec<String> = envelopes
                .iter()
                .map(|e| base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(e))
                .collect();
            surfaces.push(json!({"surface": surface, "sealed": sealed, "head": WirePosition(head)}));
        }
        json_answer("200 OK", &json!({"fromRelay": true, "surfaces": surfaces, "cut": cut}))
    }
}
