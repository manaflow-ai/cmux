//! Link previews on the Chief's replies, end to end through the brain and
//! the fake conversation owner (tests/common): a reply line that is only a
//! URL goes out as a `link_preview` part with the picture uploaded as an
//! attachment record, and the SSRF guard keeps every fetch off local,
//! private and link-local addresses (a refused fetch sends the URL only).
//! Only a URL a person wrote in the conversation is previewed; an owner
//! without `link-preview-v1`, or one that refuses the card, gets the reply
//! as its plain text.

mod common;

use std::io::Cursor;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use cmux_conversation::{DerivedImage, Op, Part};
use common::*;
use optchat_chief::link_preview::guard::{Hop, Kind, Refusal, Transport};
use optchat_chief::link_preview::picture::Picture;
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

fn jpeg(width: u32, height: u32) -> Vec<u8> {
    let image = image::RgbImage::from_fn(width, height, |x, y| {
        image::Rgb([(x * 255 / width) as u8, (y * 255 / height) as u8, 128])
    });
    let mut out = Cursor::new(Vec::new());
    image::DynamicImage::ImageRgb8(image)
        .write_to(&mut out, image::ImageFormat::Jpeg)
        .unwrap();
    out.into_inner()
}

/// A grayscale PNG of `width` x `height` (small on the wire when uniform).
fn gray_png(width: u32, height: u32) -> Vec<u8> {
    let image = image::GrayImage::from_pixel(width, height, image::Luma([200]));
    let mut out = Cursor::new(Vec::new());
    image::DynamicImage::ImageLuma8(image)
        .write_to(&mut out, image::ImageFormat::Png)
        .unwrap();
    out.into_inner()
}

/// Counts every fetch; answers none (the URL only).
#[derive(Default)]
struct Counting(AtomicUsize);

impl Fetcher for Counting {
    fn fetch(&self, _: &str, _: Instant) -> Option<Fetched> {
        self.0.fetch_add(1, Ordering::SeqCst);
        None
    }
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

/// The reply of one turn whose answer is `reply` to a person's message
/// `asked`, with `fetcher` as the brain's previewer and `owner` set up first.
fn reply_to(
    asked: &str,
    reply: &'static str,
    fetcher: Arc<dyn Fetcher>,
    owner: impl FnOnce(&mut Owner),
) -> (Vec<Part>, Harness) {
    let mut h = Harness::new(reply_script(reply));
    owner(&mut h.owner.lock().unwrap());
    h.brain.set_previewer(fetcher);
    h.connect();
    h.say("user_local", asked);
    h.settle();
    (sent_reply(&mut h), h)
}

/// A reply whose URLs the person asked about in those words.
fn reply_with(reply: &'static str, fetcher: Arc<dyn Fetcher>) -> (Vec<Part>, Harness) {
    reply_to(&format!("send me these:\n{reply}"), reply, fetcher, |_| {})
}

#[test]
fn a_reply_with_a_url_line_goes_as_text_then_a_filled_card() {
    let jpeg = jpeg(120, 60);
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

#[test]
fn a_url_only_the_agent_wrote_is_never_fetched() {
    let counting = Arc::new(Counting::default());
    let reply = "Here it is:\nhttps://example.com/x";
    let (parts, h) = reply_to("send me the link", reply, counting.clone(), |_| {});
    assert_eq!(
        counting.0.load(Ordering::SeqCst),
        0,
        "no request for a URL no person wrote"
    );
    assert_eq!(parts, vec![text(reply)], "the reply goes as its text");
    assert!(h.owner.lock().unwrap().uploads.is_empty());
}

#[test]
fn an_owner_without_link_preview_v1_gets_the_plain_text() {
    let counting = Arc::new(Counting::default());
    let reply = "Here it is:\nhttps://example.com/x";
    let (parts, _) = reply_to(
        "is https://example.com/x up?",
        reply,
        counting.clone(),
        |owner| {
            owner.no_link_previews = true;
        },
    );
    assert_eq!(counting.0.load(Ordering::SeqCst), 0);
    assert_eq!(parts, vec![text(reply)]);
}

#[test]
fn a_reply_whose_card_the_owner_refuses_goes_again_as_its_text() {
    let reply = "Here it is:\n\nhttps://example.com/x";
    let mut h = Harness::new(reply_script(reply));
    h.owner
        .lock()
        .unwrap()
        .rejects
        .push_back(Some("invalid_parts".into()));
    h.brain.set_previewer(Arc::new(Canned(None)));
    h.connect();
    h.say("user_local", "is https://example.com/x up?");
    h.settle();
    let sends = loop {
        let sends: Vec<(String, Vec<Part>)> = h
            .owner
            .lock()
            .unwrap()
            .ops
            .iter()
            .filter_map(|(key, op)| match op {
                Op::MessageSend { parts, .. } if key.starts_with("turn:") => {
                    Some((key.clone(), parts.clone()))
                }
                _ => None,
            })
            .collect();
        if sends.len() >= 2 {
            break sends;
        }
        h.step();
    };
    assert_eq!(
        sends[0].1,
        vec![text("Here it is:"), card("https://example.com/x")]
    );
    assert_eq!(
        sends[1].1,
        vec![text(reply)],
        "the original text, unchanged"
    );
    assert_ne!(
        sends[0].0, sends[1].0,
        "a new key: the refused one is spent"
    );
}

#[test]
fn a_picture_wider_than_4096_pixels_is_not_decoded() {
    let page = r#"<html><head><title>Wide</title>
<meta property="og:image" content="https://example.com/wide.png"></head></html>"#;
    let table = Arc::new(Table {
        hops: vec![
            (
                "https://example.com/page",
                Hop::Body(page.as_bytes().to_vec()),
            ),
            ("https://example.com/wide.png", Hop::Body(gray_png(4200, 8))),
        ],
        asked: Mutex::new(Vec::new()),
    });
    let (parts, h) = reply_with(
        "https://example.com/page",
        Arc::new(HttpFetcher::with_transport(table)),
    );
    assert_eq!(
        parts,
        vec![Part::LinkPreview {
            url: "https://example.com/page".into(),
            title: Some("Wide".into()),
            site: Some("example.com".into()),
            image: None,
        }]
    );
    assert!(h.owner.lock().unwrap().uploads.is_empty());
}

#[test]
fn translated_local_nat64_and_teredo_addresses_are_never_requested() {
    let page = b"<html><head><title>x</title></head></html>".to_vec();
    let urls = [
        "http://[::ffff:0:a00:1]/",
        "http://[64:ff9b:1::a00:1]/",
        "http://[2001::1]/",
    ];
    let table = Arc::new(Table {
        hops: urls.iter().map(|u| (*u, Hop::Body(page.clone()))).collect(),
        asked: Mutex::new(Vec::new()),
    });
    let (parts, _) = reply_with(
        "http://[::ffff:0:a00:1]/\nhttp://[64:ff9b:1::a00:1]/\nhttp://[2001::1]/",
        Arc::new(HttpFetcher::with_transport(table.clone())),
    );
    assert!(
        table.asked.lock().unwrap().is_empty(),
        "{:?}",
        table.asked.lock().unwrap()
    );
    assert_eq!(parts, urls.iter().map(|u| card(u)).collect::<Vec<_>>());
}

#[test]
fn a_shortened_query_or_host_of_a_persons_url_gets_no_card() {
    for (asked, reply) in [
        (
            "open https://example.com/x?id=1&token=abc",
            "https://example.com/x?id=1",
        ),
        ("see https://example.com.au/page", "https://example.com"),
    ] {
        let counting = Arc::new(Counting::default());
        let (parts, _) = reply_to(asked, reply, counting.clone(), |_| {});
        assert_eq!(counting.0.load(Ordering::SeqCst), 0, "{asked}");
        assert_eq!(parts, vec![text(reply)], "{asked}");
    }
}

#[test]
fn the_exact_url_inside_a_longer_sentence_gets_a_card() {
    for asked in [
        "is https://example.com/x up, or not?",
        "(see https://example.com/x).",
        "<https://example.com/x>",
    ] {
        let counting = Arc::new(Counting::default());
        let (parts, _) = reply_to(asked, "https://example.com/x", counting.clone(), |_| {});
        assert_eq!(counting.0.load(Ordering::SeqCst), 1, "{asked}");
        assert_eq!(parts, vec![card("https://example.com/x")], "{asked}");
    }
}

#[test]
fn a_url_in_a_persons_link_preview_title_does_not_count() {
    let counting = Arc::new(Counting::default());
    let reply = "https://example.com/x";
    let mut h = Harness::new(reply_script(reply));
    h.brain.set_previewer(counting.clone());
    h.connect();
    h.say_parts(
        "user_local",
        vec![
            text("look"),
            Part::LinkPreview {
                url: "https://a.example/".into(),
                title: Some("https://example.com/x".into()),
                site: None,
                image: None,
            },
        ],
    );
    h.settle();
    assert_eq!(sent_reply(&mut h), vec![text(reply)]);
    assert_eq!(counting.0.load(Ordering::SeqCst), 0);
}
