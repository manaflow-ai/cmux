use cmux_mobile_link::dial::wireguard::RoamMessage;
use cmux_mobile_link::signaling::*;
use serde::{
    Serialize,
    de::{self, DeserializeOwned},
};
use serde_json::Value;
use std::collections::BTreeSet;
use std::fmt;

// Serde's derived tagged-enum decoder reports its actual accepted tags when given
// an unknown one. No fixture can silently omit a variant that the decoder accepts.
#[derive(Debug, thiserror::Error)]
#[error("{0:?}")]
struct ExpectedTags(&'static [&'static str]);

impl de::Error for ExpectedTags {
    fn custom<T: fmt::Display>(message: T) -> Self {
        panic!("expected a tagged enum, got {message}")
    }
    fn unknown_variant(_: &str, expected: &'static [&'static str]) -> Self {
        Self(expected)
    }
}

fn tags<T: DeserializeOwned>(tag: &str) -> BTreeSet<&'static str> {
    let invalid = [(tag, "__unknown_wire_tag__")];
    let decoder = de::value::MapDeserializer::<_, ExpectedTags>::new(invalid.into_iter());
    match T::deserialize(decoder) {
        Err(ExpectedTags(expected)) => expected.iter().copied().collect(),
        Ok(_) => panic!("{} accepted unknown wire tag", std::any::type_name::<T>()),
    }
}

pub(super) fn payload_tags() -> BTreeSet<&'static str> {
    tags::<SignalPayload>("kind")
}

pub(super) fn collect(value: &Value, parent: &str, names: &mut BTreeSet<String>) {
    let Some(object) = value.as_object() else { return };
    let tag = ["kind", "type", "t"].into_iter().find_map(|key| object.get(key).and_then(Value::as_str));
    let context = tag.unwrap_or(parent);
    if let Some(tag) = tag {
        names.insert(format!("event:{tag}"));
    }
    for (key, child) in object {
        if key == "type" || key == "kind" {
            continue;
        }
        names.insert(format!("field:{context}#{key}"));
        let nested = match (context, key.as_str()) {
            ("presence", "mac") | ("hello", "macs") => "mac".to_owned(),
            _ => format!("{context}.{key}"),
        };
        if let Some(items) = child.as_array() {
            for item in items {
                collect(item, &nested, names);
            }
        } else {
            collect(child, &nested, names);
        }
    }
}

fn add_samples<T: DeserializeOwned + Serialize>(
    names: &mut BTreeSet<String>,
    tag: &str,
    samples: impl IntoIterator<Item = T>,
) {
    let mut sampled = BTreeSet::new();
    for sample in samples {
        let value = serde_json::to_value(sample).unwrap();
        sampled.insert(value[tag].as_str().unwrap().to_owned());
        collect(&value, "", names);
    }
    assert_eq!(
        sampled,
        tags::<T>(tag).into_iter().map(str::to_owned).collect(),
        "missing wire fixture for {}",
        std::any::type_name::<T>()
    );
}

pub(super) fn names() -> BTreeSet<String> {
    let messages = [
        SignalMessage::Hello {
            you: "device".into(),
            macs: vec![MacPresence {
                device_id: "mac".into(),
                name: "Mac".into(),
                online: true,
                last_seen_at: Some(serde_json::json!(1)),
                owner_user_id: Some("user".into()),
            }],
            hub_version: 1,
        },
        SignalMessage::Presence {
            mac: MacPresence {
                device_id: "mac".into(),
                name: "Mac".into(),
                online: true,
                last_seen_at: Some(serde_json::json!(1)),
                owner_user_id: Some("user".into()),
            },
        },
        SignalMessage::Signal(SignalEnvelope {
            to: "mac".into(),
            from: "phone".into(),
            session_id: "session".into(),
            payload: SignalPayload::Bye { reason: "closed".into() },
            from_user_id: Some("user".into()),
            relay_ticket: Some("ticket".into()),
        }),
        SignalMessage::Mailbox {
            items: vec![MailboxItem {
                id: "id".into(),
                from: "phone".into(),
                sealed: "sealed".into(),
                at: Some(1),
            }],
        },
        SignalMessage::MailboxAck {
            results: vec![MailboxResult {
                id: "id".into(),
                applied: true,
                reason: Some("ok".into()),
                sig: Some("sig".into()),
            }],
        },
        SignalMessage::Error {
            code: "bad_request".into(),
            message: "message".into(),
            session_id: Some("session".into()),
        },
    ];
    let payloads = [
        SignalPayload::WebrtcOffer {
            sdp: "sdp".into(),
            lanes: vec!["input".into()],
            media_for: Some("link".into()),
        },
        SignalPayload::WebrtcAnswer { sdp: "sdp".into(), lanes: vec!["input".into()] },
        SignalPayload::WebrtcIce {
            candidate: "candidate".into(),
            sdp_mid: Some("0".into()),
            sdp_m_line_index: Some(0),
        },
        SignalPayload::WgInit {
            public_key: "key".into(),
            endpoints: vec!["127.0.0.1:1".into()],
            overlay_ip: "10.0.0.1".into(),
            lanes: vec!["input".into()],
            relayed: vec!["127.0.0.1:2".into()],
            relayed_tls: vec!["127.0.0.1:2".into()],
            version: WG_VERSION,
            relay: Some("relay".into()),
        },
        SignalPayload::WgResp {
            public_key: "key".into(),
            endpoints: vec!["127.0.0.1:1".into()],
            overlay_ip: "10.0.0.2".into(),
            lanes: vec!["input".into()],
            relayed: vec!["127.0.0.1:2".into()],
            relayed_tls: vec!["127.0.0.1:2".into()],
            version: WG_VERSION,
            relay: Some("relay".into()),
        },
        SignalPayload::WgEndpoints {
            generation: 1,
            endpoints: vec!["127.0.0.1:1".into()],
            relayed: vec!["127.0.0.1:2".into()],
            relayed_tls: vec!["127.0.0.1:2".into()],
        },
        SignalPayload::WgRelay {},
        SignalPayload::Bye { reason: "closed".into() },
    ];
    let roam = [
        RoamMessage::Endpoints {
            generation: 1,
            endpoints: vec!["127.0.0.1:1".into()],
            relayed: vec!["127.0.0.1:2".into()],
            relayed_tls: vec!["127.0.0.1:2".into()],
        },
        RoamMessage::Ack { generation: 1 },
        RoamMessage::Reach { from: Some("127.0.0.1:1".into()), via: Some("udp".into()) },
    ];
    let mut names = BTreeSet::new();
    add_samples(&mut names, "type", messages);
    add_samples(&mut names, "kind", payloads);
    add_samples(&mut names, "t", roam);
    names
}
