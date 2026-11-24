use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use cmux_mobile_host::paint_latency::Report;
use cmux_mobile_host::phone_frames::Pan;
use cmux_mobile_host::services::{LINK_PROTOCOL, version_reply};
use cmux_mobile_link::frame::FrameType;
use cmux_mobile_link::key_echo;
use cmux_mobile_link::link::{self, CloseInfo, OpenRequest};
use cmux_mobile_link::link_stat::{self, LinkStat, Reason, RttSummary};
use cmux_mobile_link::names::{self, HostService};
use cmux_mobile_link::{build_space, dial, signaling};
use cmux_wire_lockstep::{Manifest, OldPeer, assert_manifest_current, base_manifest};
use serde::Serialize;
use serde::de::{DeserializeOwned, Deserializer, Error, Visitor};
use serde_json::Value;

fn path() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../../cmux-tui/spec/wire/mobile-link.json")
}

pub(super) fn base() -> OldPeer {
    let snapshot = std::fs::read_to_string(path()).expect("committed mobile-link manifest");
    OldPeer::new(base_manifest("mobile-link", &snapshot).unwrap())
}

fn fields(set: &mut BTreeSet<String>, message: &str, value: impl Serialize) {
    let value = serde_json::to_value(value).unwrap();
    for key in value.as_object().unwrap().keys().filter(|key| key.as_str() != "type") {
        set.insert(format!("field:{message}#{key}"));
    }
}

// A derive(Deserialize) struct supplies all accepted field names to its deserializer,
// including optional fields absent from an ordinary example on the wire.
struct StructFields<'a>(&'a mut &'static [&'static str]);

impl<'de> Deserializer<'de> for StructFields<'_> {
    type Error = serde::de::value::Error;

    fn deserialize_struct<V: Visitor<'de>>(
        self,
        _: &'static str,
        fields: &'static [&'static str],
        _: V,
    ) -> Result<V::Value, Self::Error> {
        *self.0 = fields;
        Err(Self::Error::custom("collected fields"))
    }

    fn deserialize_any<V: Visitor<'de>>(self, _: V) -> Result<V::Value, Self::Error> {
        Err(Self::Error::custom("expected a struct"))
    }

    serde::forward_to_deserialize_any! {
        bool i8 i16 i32 i64 i128 u8 u16 u32 u64 u128 f32 f64 char str string bytes byte_buf
        option unit unit_struct newtype_struct seq tuple tuple_struct map enum identifier ignored_any
    }
}

fn schema_fields<T: DeserializeOwned>(set: &mut BTreeSet<String>, context: &str) {
    let mut keys = &[][..];
    let _ = T::deserialize(StructFields(&mut keys));
    assert!(!keys.is_empty(), "{} must have named fields", std::any::type_name::<T>());
    set.extend(keys.iter().map(|key| format!("field:{context}#{key}")));
}

pub(super) fn manifest() -> Manifest {
    let mut manifest = Manifest::new(
        "mobile-link",
        "hostd version.capabilities; daemon identify/set-client-info; signaling offer/answer lanes and WireGuard version; _link.park encoding",
    );
    for cap in names::ALL {
        for name in cap.wire_names {
            if let Some(service) = name.strip_prefix("service:") {
                assert!(
                    HostService::parse(service).is_some(),
                    "{} gates unknown host service {service}",
                    cap.name
                );
            }
        }
        let names = cap.wire_names.iter().map(|name| (*name).to_owned()).collect();
        assert!(manifest.capabilities.insert(cap.name.to_owned(), names).is_none());
    }
    manifest
        .capabilities
        .insert(link::PARK_ENCODING.to_owned(), [FrameType::DeflatedData.wire_name().to_owned()].into());
    manifest
        .capabilities
        .insert(dial::WEBRTC_MEDIA_LANE.to_owned(), ["field:webrtc-offer#mediaFor".to_owned()].into());
    manifest.capabilities.insert(
        link::LIVENESS_LANE.to_owned(),
        [
            format!("control:liveness/ping={}", link::DATAGRAM_PING),
            format!("control:liveness/pong={}", link::DATAGRAM_PONG),
        ]
        .into(),
    );
    // A channel's messages also travel as class datagrams only between peers that both list it.
    manifest.capabilities.insert(
        cmux_mobile_link::classes::CLASSES_LANE.to_owned(),
        [
            FrameType::Sequenced.wire_name().to_owned(),
            format!("control:liveness/class={}", cmux_mobile_link::classes::DATAGRAM_CLASS),
            format!("control:liveness/screen={}", cmux_mobile_link::classes::DATAGRAM_SCREEN),
        ]
        .into(),
    );
    // Reach is sent only on a v2 tunnel. Peers send the endpoint announcements on every version.
    manifest.capabilities.insert(
        format!("wg-version={}", signaling::WG_VERSION),
        ["event:reach", "field:reach#t", "field:reach#from", "field:reach#via"].map(str::to_owned).into(),
    );
    manifest.versions.insert("hostd-link".into(), LINK_PROTOCOL);
    manifest.versions.insert("link_stat".into(), link_stat::VERSION.into());
    manifest.versions.insert("wireguard".into(), signaling::WG_VERSION);
    manifest.accepts.insert("wireguard".into(), [0, signaling::WG_VERSION].into());

    let mut vocabulary = super::signals::names();
    vocabulary.extend(super::worker::control_names());
    // These two controls were added after phone-frames-v1 without a new capability.
    use cmux_mobile_host::paint_latency::{Line, clock_answer, kind_of};
    let clock: Value = serde_json::from_slice(&clock_answer(1.0, 2.0)).unwrap();
    let paint = serde_json::json!({"kind":"paint","samples":[]});
    for line in [clock, paint] {
        let kind = line["kind"].as_str().unwrap();
        assert_eq!(
            kind,
            match kind_of(&serde_json::to_vec(&line).unwrap()).unwrap() {
                Line::Clock(_) => "clock",
                Line::Paint => "paint",
            }
        );
        vocabulary.insert(format!("control:phone-frames/{kind}"));
        fields(&mut vocabulary, &format!("phone-frames/{kind}"), &line);
    }
    schema_fields::<Report>(&mut vocabulary, "phone-frames/paint");
    // The pan schema is shared by both original phone-frames-v1 message kinds.
    let pans = manifest.capabilities.get_mut(names::PHONE_FRAMES).unwrap();
    for kind in ["tui", "scrollback"] {
        assert!(pans.contains(&format!("control:phone-frames/{kind}")));
        schema_fields::<Pan>(pans, &format!("phone-frames/{kind}"));
    }
    vocabulary.extend(FrameType::ALL.iter().map(|frame| frame.wire_name().to_owned()));
    vocabulary.extend(HostService::ALL.iter().map(|service| format!("service:{}", service.as_str())));
    vocabulary.insert(format!("service:{}", link::PARK_SERVICE));
    // The phone creates the input data channel before the answer lists supported lanes.
    for label in [dial::webrtc::LABEL, dial::webrtc::INPUT_LABEL] {
        vocabulary.insert(format!("control:data-channel/{label}"));
    }
    for key in ["encoding", "hold_ms"] {
        vocabulary.insert(format!("param:{}#{key}", link::PARK_SERVICE));
    }
    // The auth channel uses untagged JSON objects. Open parameters and data fields
    // have different contracts even when a key appears in both.
    vocabulary.extend(
        [
            "kind",
            "identityKey",
            "approvalKey",
            "action",
            "name",
            "bundleId",
            "appBuild",
            "macNonce",
            "pushKey",
            "pushKeySignature",
        ]
        .map(|key| format!("param:auth#{key}")),
    );
    vocabulary.extend(
        [
            "challenge",
            "mac",
            "macKey",
            "macSignature",
            "macBoxKey",
            "macBoxSignature",
            "signature",
            "ok",
            "pending",
        ]
        .map(|key| format!("field:auth#{key}")),
    );
    vocabulary.extend(["pair", "unpair"].map(|action| format!("control:auth/{action}")));
    // Worker presence carries additional optional properties beyond Rust's MacPresence projection.
    vocabulary.extend(["machineId", "quietMs", "removed"].map(|key| format!("field:mac#{key}")));
    schema_fields::<OpenRequest>(&mut vocabulary, "open");
    schema_fields::<CloseInfo>(&mut vocabulary, "close");
    fields(&mut vocabulary, "version", version_reply(&super::host_service::config()));

    // CloseInfo also carries application-defined reasons. These are the protocol-owned codes.
    for code in [
        "asleep",
        "bad_channel",
        "bad_request",
        "busy",
        "cancelled",
        "closed",
        "denied",
        "dropped",
        "ended",
        "eof",
        "evicted",
        "fingerprint_mismatch",
        "forbidden",
        "io",
        "link_closed",
        "link_failed",
        "no_browser_host",
        "no_surface_host",
        "no_waiting_request",
        "not_found",
        "not_offered",
        "overflow",
        link::PARKED,
        "phone_closed",
        "protocol",
        "rate_limited",
        "refused",
        "replaced",
        "revoked",
        "stale",
        "stalled",
        "timeout",
        "too_large",
        "unavailable",
        "unknown_service",
        "unpaired",
    ] {
        vocabulary.insert(format!("control:close/{code}"));
    }
    vocabulary.extend(
        [signaling::APP_PING, signaling::APP_PONG].map(|word| format!("control:signaling-text/{word}")),
    );
    vocabulary.extend(["ping", "pong"].map(|word| format!("control:websocket/{word}")));
    vocabulary.insert(format!("header:{}", build_space::HEADER));
    vocabulary.insert("header:authorization".into());
    let stat = LinkStat {
        kind: "link_stat",
        v: link_stat::VERSION,
        transport: "webrtc",
        path: "direct",
        reason: Reason::First,
        setup_ms: Some(0),
        marks: link_stat::MARKS.iter().map(|&mark| (mark, 0)).collect(),
        rtt: RttSummary::of(&[1]),
        pings: 1,
        lost: 0,
        switches: 0,
        net: "other",
        up_s: 0,
        end: Some("app"),
        lib: "test",
        // Every optional field set, so each one's wire name is in the manifest.
        echo: key_echo::Summary::of(&[1]),
        ack: key_echo::Summary::of(&[1]),
        spike_count: 1,
        spikes: vec![[0, 1, 1]],
    };
    vocabulary.insert(format!("event:{}", stat.kind));
    fields(&mut vocabulary, stat.kind, &stat);
    fields(&mut vocabulary, "link_stat.rtt", stat.rtt.unwrap());
    fields(&mut vocabulary, "link_stat.marks", &stat.marks);
    fields(&mut vocabulary, "link_stat.echo", stat.echo.unwrap());
    fields(&mut vocabulary, "link_stat.ack", stat.ack.unwrap());
    let gated = manifest.names();
    manifest.legacy = vocabulary.into_iter().filter(|name| !gated.contains(name.as_str())).collect();
    manifest
}

#[test]
fn mobile_link_manifest_is_current() {
    assert_manifest_current(&manifest(), &path()).unwrap();
}
