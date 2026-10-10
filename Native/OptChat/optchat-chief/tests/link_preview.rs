//! Link previews on the Chief's replies, end to end through the brain and
//! the fake conversation owner (tests/common): a reply line that is only a
//! URL goes out as a `link_preview` part with the picture uploaded as an
//! attachment record, and the SSRF guard keeps every fetch off local,
//! private and link-local addresses (a refused fetch sends the URL only).

mod common;

use std::io::Cursor;
use std::sync::{Arc, Mutex};
use std::time::Instant;

use cmux_conversation::{DerivedImage, Op, Part};
use common::*;
use optchat_chief::link_preview::guard::{Hop, Kind, Refusal, Transport};
use optchat_chief::link_preview::picture::{Picture, to_jpeg};
use optchat_chief::link_preview::{Fetched, Fetcher, HttpFetcher};
use serde_json::json;
use url::Url;

fn text(t: &str) -> Part {
    Part::Text {
        text: t.into(),
        runs: None,
    }
}

fn card(url: &str) -> Part {
    Part::LinkPreview {
        url: url.into(),
        title: None,
        site: None,
        image: None,
    }
}

fn png(width: u32, height: u32) -> Vec<u8> {
    let image = image::RgbaImage::from_fn(width, height, |x, y| {
        image::Rgba([(x * 255 / width) as u8, (y * 255 / height) as u8, 128, 200])
    });
    let mut out = Cursor::new(Vec::new());
    image::DynamicImage::ImageRgba8(image)
        .write_to(&mut out, image::ImageFormat::Png)
        .unwrap();
    out.into_inner()
}

/// A fetcher that answers every URL from memory (no network).
struct Canned(Option<Fetched>);

impl Fetcher for Canned {
    fn fetch(&self, _: &str, _: Instant) -> Option<Fetched> {
        self.0.clone()
    }
}

/// A transport that answers from a table and records each request it got
/// (the guard runs before it: a refused URL never reaches it).
struct Table {
    hops: Vec<(&'static str, Hop)>,
    asked: Mutex<Vec<String>>,
}

impl Transport for Table {
    fn get(&self, url: &Url, _: Kind, _: Instant) -> Result<Hop, Refusal> {
        self.asked.lock().unwrap().push(url.to_string());
        self.hops
            .iter()
            .find(|(u, _)| *u == url.as_str())
            .map(|(_, hop)| hop.clone())
            .ok_or(Refusal::Status(404))
    }
}

fn reply_script(text: &'static str) -> Script {
    Box::new(move |_, _| {
        vec![
            json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
            update(
                "agent_message_chunk",
                json!({"content": {"type": "text", "text": text}}),
            ),
            json!({"dir": "mux", "kind": "turn_end", "msg": {}}),
        ]
    })
}

/// The parts of the reply once the owner took it.
fn sent_reply(h: &mut Harness) -> Vec<Part> {
    loop {
        let sent = h
            .owner
            .lock()
            .unwrap()
            .ops
            .iter()
            .find_map(|(key, op)| match op {
                Op::MessageSend { parts, .. } if key.starts_with("turn:") => Some(parts.clone()),
                _ => None,
            });
        if let Some(parts) = sent {
            return parts;
        }
        h.step();
    }
}

/// The reply of one turn whose answer is `reply`, with `fetcher` as the
/// brain's previewer.
fn reply_with(reply: &'static str, fetcher: Arc<dyn Fetcher>) -> (Vec<Part>, Harness) {
    let mut h = Harness::new(reply_script(reply));
    h.brain.set_previewer(fetcher);
    h.connect();
    h.say("user_local", "send me the link");
    h.settle();
    (sent_reply(&mut h), h)
}

#[test]
fn a_reply_with_a_url_line_goes_as_text_then_a_filled_card() {
    let jpeg = to_jpeg(&png(120, 60)).unwrap().jpeg;
    let (parts, h) = reply_with(
        "Here it is:\nhttps://example.com/x",
        Arc::new(Canned(Some(Fetched {
            title: Some("Example X".into()),
            site: Some("example.com".into()),
            picture: Some(Picture {
                jpeg: jpeg.clone(),
                width: 120,
                height: 60,
            }),
        }))),
    );
    let uploads = h.owner.lock().unwrap().uploads.clone();
    assert_eq!(uploads.len(), 1, "the picture is uploaded once");
    let (conversation, image, name, width, height) = &uploads[0];
    assert_eq!(conversation, CONV);
    assert_eq!(
        (name.as_str(), *width, *height),
        ("link-preview.jpg", 120, 60)
    );
    assert_eq!(
        image,
        &DerivedImage {
            hash: image.hash.clone(),
            mime_type: "image/jpeg".into(),
            byte_count: jpeg.len() as u64,
        }
    );
    assert_eq!(
        parts,
        vec![
            text("Here it is:"),
            Part::LinkPreview {
                url: "https://example.com/x".into(),
                title: Some("Example X".into()),
                site: Some("example.com".into()),
                image: Some(image.clone()),
            },
        ]
    );
}

#[test]
fn a_failed_fetch_sends_the_card_with_its_url_only() {
    let (parts, h) = reply_with("Here it is:\nhttps://example.com/x", Arc::new(Canned(None)));
    assert_eq!(
        parts,
        vec![text("Here it is:"), card("https://example.com/x")]
    );
    assert!(h.owner.lock().unwrap().uploads.is_empty());
}

#[test]
fn links_to_local_private_and_link_local_hosts_are_never_fetched() {
    // The network fetcher: the guard refuses each of these before any
    // connection (a literal address, or a name that resolves to loopback).
    let (parts, h) = reply_with(
        "Look:\nhttp://127.0.0.1/admin\nhttp://localhost/\nhttp://169.254.169.254/latest/meta-data\nhttp://[::1]/\nhttp://10.0.0.1/",
        Arc::new(HttpFetcher::new()),
    );
    assert_eq!(
        parts,
        vec![
            text("Look:"),
            card("http://127.0.0.1/admin"),
            card("http://localhost/"),
            card("http://169.254.169.254/latest/meta-data"),
            card("http://[::1]/"),
            card("http://10.0.0.1/"),
        ]
    );
    assert!(h.owner.lock().unwrap().uploads.is_empty());
}

#[test]
fn a_redirect_or_an_image_on_a_private_address_is_never_requested() {
    let page = r#"<html><head><title>Public page</title>
<meta property="og:image" content="http://192.168.1.1/card.png"></head></html>"#;
    let table = Arc::new(Table {
        hops: vec![
            (
                "https://example.com/redirect",
                Hop::Redirect("https://169.254.169.254/latest".into()),
            ),
            (
                "https://example.com/page",
                Hop::Body(page.as_bytes().to_vec()),
            ),
        ],
        asked: Mutex::new(Vec::new()),
    });
    let (parts, h) = reply_with(
        "https://example.com/redirect\nhttps://example.com/page",
        Arc::new(HttpFetcher::with_transport(table.clone())),
    );
    let mut asked = table.asked.lock().unwrap().clone();
    asked.sort();
    assert_eq!(
        asked,
        vec!["https://example.com/page", "https://example.com/redirect"],
        "neither the redirect target nor the private image is requested"
    );
    assert_eq!(
        parts,
        vec![
            card("https://example.com/redirect"),
            Part::LinkPreview {
                url: "https://example.com/page".into(),
                title: Some("Public page".into()),
                site: Some("example.com".into()),
                image: None,
            },
        ]
    );
    assert!(h.owner.lock().unwrap().uploads.is_empty());
}
