//! Link previews on the Chief's replies (src/link_preview, brain/previews.rs):
//! the line rule, the SSRF guard, the page metadata, the preview picture, the
//! concurrent fetch, and a reply that goes out as text plus a filled card.

mod common;

use std::io::Cursor;
use std::net::IpAddr;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use cmux_conversation::{DerivedImage, MAX_PARTS, Op, Part};
use common::*;
use optchat_chief::link_preview::guard::{
    HTML_LIMIT, Hop, Kind, Refusal, Transport, check_url, guarded_get, is_public_ip, read_capped,
    read_html, resolve_public,
};
use optchat_chief::link_preview::meta::{page_meta, strip_site, title_tag};
use optchat_chief::link_preview::picture::{Picture, to_jpeg};
use optchat_chief::link_preview::split::text_parts;
use optchat_chief::link_preview::{Fetched, Fetcher, HttpFetcher, fetch_all};
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

// MARK: the line rule

#[test]
fn a_line_that_is_only_a_url_becomes_a_card_in_its_place() {
    assert_eq!(
        text_parts("Here it is:\nhttps://example.com/x"),
        vec![text("Here it is:"), card("https://example.com/x")]
    );
    assert_eq!(
        text_parts("a\nb\n  https://example.com/1  \nc"),
        vec![text("a\nb"), card("https://example.com/1"), text("c")]
    );
    assert_eq!(
        text_parts("https://example.com"),
        vec![card("https://example.com")]
    );
    assert_eq!(
        text_parts("HTTP://Example.com/A\nhttps://example.org/b"),
        vec![card("HTTP://Example.com/A"), card("https://example.org/b")]
    );
}

#[test]
fn blank_lines_around_a_card_make_no_text_part() {
    assert_eq!(
        text_parts("first\n\n  \nhttps://example.com/x\n\n\nsecond\n\nthird\n"),
        vec![
            text("first"),
            card("https://example.com/x"),
            text("second\n\nthird")
        ]
    );
}

#[test]
fn a_url_inside_a_sentence_or_not_http_stays_text() {
    for t in [
        "see https://example.com/x for details",
        "https://example.com/x.",
        "(https://example.com/x)",
        "ftp://example.com/file",
        "example.com",
        "https://user:pw@example.com/",
        "<https://example.com/x>",
        "```\nhttps://example.com/x\n```",
    ] {
        assert_eq!(text_parts(t), vec![text(t)], "{t:?} stays one text part");
    }
}

#[test]
fn more_cards_than_parts_allow_leave_the_last_urls_as_text() {
    let lines: Vec<String> = (0..20)
        .map(|i| format!("https://example.com/{i}"))
        .collect();
    let parts = text_parts(&lines.join("\n"));
    assert_eq!(parts.len(), MAX_PARTS);
    assert!(
        parts[..MAX_PARTS - 1]
            .iter()
            .all(|p| matches!(p, Part::LinkPreview { .. }))
    );
    assert_eq!(
        parts[MAX_PARTS - 1],
        text(&lines[MAX_PARTS - 1..].join("\n"))
    );
}

// MARK: the guard

fn refusal(url: &str) -> Option<Refusal> {
    check_url(&Url::parse(url).unwrap()).err()
}

#[test]
fn the_guard_refuses_local_private_ports_and_credentials() {
    for url in [
        "http://localhost/",
        "http://app.localhost/",
        "http://printer.local/",
        "http://metadata.google.internal/",
        "http://nas.lan/",
        "http://router.home.arpa/",
        "http://wiki.intranet/",
        "http://jira.corp/",
        "http://intranet/",
        "http://127.0.0.1/",
        "http://2130706433/",
        "http://0x7f.1/",
        "http://10.1.2.3/",
        "http://172.16.0.1/",
        "http://192.168.1.1/",
        "http://100.100.100.100/",
        "http://169.254.169.254/latest/meta-data",
        "http://0.0.0.0/",
        "http://255.255.255.255/",
        "http://224.0.0.1/",
        "http://192.0.2.1/",
        "http://198.18.0.1/",
        "http://[::1]/",
        "http://[::]/",
        "http://[::ffff:127.0.0.1]/",
        "http://[::ffff:10.0.0.1]/",
        "http://[::7f00:1]/",
        "http://[64:ff9b::a9fe:a9fe]/",
        "http://[2002:c0a8:101::1]/",
        "http://[fe80::1]/",
        "http://[fd12:3456::1]/",
        "http://[ff02::1]/",
        "http://[2001:db8::1]/",
    ] {
        assert!(refusal(url).is_some(), "{url} must be refused");
    }
    assert_eq!(refusal("https://example.com:8443/"), Some(Refusal::Port));
    assert_eq!(refusal("http://example.com:443/"), Some(Refusal::Port));
    assert_eq!(
        refusal("https://user:pw@example.com/"),
        Some(Refusal::Credentials)
    );
    assert_eq!(
        refusal("https://user@example.com/"),
        Some(Refusal::Credentials)
    );
    assert_eq!(refusal("ftp://example.com/"), Some(Refusal::Scheme));
    assert_eq!(refusal("file:///etc/passwd"), Some(Refusal::Scheme));
}

#[test]
fn the_guard_accepts_public_literals_names_and_default_ports() {
    for url in [
        "https://93.184.215.14/",
        "http://8.8.8.8/",
        "https://[2606:4700:4700::1111]/",
        "https://[::ffff:8.8.8.8]/",
        "https://example.com/",
        "https://example.com:443/x",
        "http://example.com:80/x",
        "https://www.example.co.uk/a?b=c#d",
    ] {
        assert_eq!(refusal(url), None, "{url} must be allowed");
    }
    assert!(is_public_ip("1.1.1.1".parse::<IpAddr>().unwrap()));
    assert!(!is_public_ip("100.64.0.1".parse::<IpAddr>().unwrap()));
}

#[test]
fn resolution_requires_every_address_public() {
    assert_eq!(
        resolve_public("127.0.0.1", 80),
        Err(Refusal::Address("127.0.0.1".into()))
    );
    assert_eq!(
        resolve_public("[fd00::1]", 443),
        Err(Refusal::Address("fd00::1".into()))
    );
    let ok = resolve_public("8.8.8.8", 443).unwrap();
    assert_eq!(ok, vec!["8.8.8.8:443".parse().unwrap()]);
}

/// A transport that answers from a table and records each request.
struct Table {
    hops: Vec<(&'static str, Hop)>,
    asked: Mutex<Vec<String>>,
}

impl Table {
    fn new(hops: Vec<(&'static str, Hop)>) -> Table {
        Table {
            hops,
            asked: Mutex::new(Vec::new()),
        }
    }
}

impl Transport for Table {
    fn get(&self, url: &Url, _: Kind, _: Instant) -> Result<Hop, Refusal> {
        self.asked.lock().unwrap().push(url.to_string());
        self.hops
            .iter()
            .find(|(u, _)| *u == url.as_str())
            .map(|(_, hop)| hop.clone())
            .ok_or_else(|| Refusal::Status(404))
    }
}

fn soon() -> Instant {
    Instant::now() + Duration::from_secs(5)
}

#[test]
fn a_redirect_to_a_private_address_is_refused_before_it_is_requested() {
    let table = Table::new(vec![(
        "https://example.com/x",
        Hop::Redirect("http://127.0.0.1/admin".into()),
    )]);
    let got = guarded_get(&table, "https://example.com/x", Kind::Html, soon());
    assert!(matches!(got, Err(Refusal::Downgrade | Refusal::Address(_))));
    let table = Table::new(vec![(
        "https://example.com/x",
        Hop::Redirect("https://169.254.169.254/latest".into()),
    )]);
    assert_eq!(
        guarded_get(&table, "https://example.com/x", Kind::Html, soon()),
        Err(Refusal::Address("169.254.169.254".into()))
    );
    assert_eq!(*table.asked.lock().unwrap(), vec!["https://example.com/x"]);
    let table = Table::new(vec![(
        "https://example.com/x",
        Hop::Redirect("http://example.com/y".into()),
    )]);
    assert_eq!(
        guarded_get(&table, "https://example.com/x", Kind::Html, soon()),
        Err(Refusal::Downgrade)
    );
}

#[test]
fn redirects_are_followed_five_times_at_most() {
    let chain: Vec<(&'static str, Hop)> = vec![
        ("https://example.com/0", Hop::Redirect("/1".into())),
        ("https://example.com/1", Hop::Redirect("/2".into())),
        ("https://example.com/2", Hop::Redirect("/3".into())),
        ("https://example.com/3", Hop::Redirect("/4".into())),
        (
            "https://example.com/4",
            Hop::Redirect("https://example.org/5".into()),
        ),
        (
            "https://example.org/5",
            Hop::Body(b"<title>five</title>".to_vec()),
        ),
    ];
    let (url, body) = guarded_get(
        &Table::new(chain),
        "https://example.com/0",
        Kind::Html,
        soon(),
    )
    .unwrap();
    assert_eq!(url.as_str(), "https://example.org/5");
    assert_eq!(body, b"<title>five</title>");
    let chain: Vec<(&'static str, Hop)> = vec![
        ("https://example.com/0", Hop::Redirect("/1".into())),
        ("https://example.com/1", Hop::Redirect("/2".into())),
        ("https://example.com/2", Hop::Redirect("/3".into())),
        ("https://example.com/3", Hop::Redirect("/4".into())),
        ("https://example.com/4", Hop::Redirect("/5".into())),
        ("https://example.com/5", Hop::Redirect("/6".into())),
        ("https://example.com/6", Hop::Body(Vec::new())),
    ];
    assert_eq!(
        guarded_get(
            &Table::new(chain),
            "https://example.com/0",
            Kind::Html,
            soon()
        ),
        Err(Refusal::RedirectLimit)
    );
}

#[test]
fn html_stops_at_the_end_of_the_head_and_images_have_a_cap() {
    let page = format!(
        "<html><HEAD><title>t</title></HEAD><body>{}</body>",
        "x".repeat(100_000)
    );
    let head = read_html(&mut Cursor::new(page.into_bytes()), HTML_LIMIT, soon()).unwrap();
    assert_eq!(head, b"<html><HEAD><title>t</title></HEAD>");
    let long = "y".repeat(HTML_LIMIT + 10);
    let cut = read_html(&mut Cursor::new(long.into_bytes()), HTML_LIMIT, soon()).unwrap();
    assert_eq!(cut.len(), HTML_LIMIT);
    assert_eq!(
        read_capped(&mut Cursor::new(vec![0u8; 101]), 100, soon()),
        Err(Refusal::TooLarge)
    );
    assert_eq!(
        read_capped(&mut Cursor::new(vec![7u8; 100]), 100, soon()).unwrap(),
        vec![7u8; 100]
    );
}

// MARK: metadata

const PAGE: &str = r#"<!doctype html><html><head>
<title>GitHub - manaflow-ai/cmux: ignored title tag</title>
<meta content="GitHub - manaflow-ai/cmux: A terminal &amp; more" property="og:title">
<meta property='og:site_name' content='GitHub'>
<meta name="twitter:title" content="twitter title">
<META PROPERTY="og:image" CONTENT="/img/card.png?v=1&amp;s=2">
</head><body></body></html>"#;

#[test]
fn metadata_takes_og_tags_strips_the_site_and_resolves_the_image() {
    let page = Url::parse("https://www.github.com/manaflow-ai/cmux").unwrap();
    let meta = page_meta(PAGE, &page);
    assert_eq!(
        meta.title.as_deref(),
        Some("manaflow-ai/cmux: A terminal & more")
    );
    assert_eq!(meta.site.as_deref(), Some("github.com"));
    assert_eq!(
        meta.image.map(|u| u.to_string()).as_deref(),
        Some("https://www.github.com/img/card.png?v=1&s=2")
    );
}

#[test]
fn metadata_falls_back_to_twitter_then_the_title_tag() {
    let page = Url::parse("https://example.com/a/b").unwrap();
    let twitter = r#"<head><meta name="twitter:title" content="Tweet"><meta name="twitter:image" content="pic.jpg"></head>"#;
    let meta = page_meta(twitter, &page);
    assert_eq!(meta.title.as_deref(), Some("Tweet"));
    assert_eq!(
        meta.image.map(|u| u.to_string()).as_deref(),
        Some("https://example.com/a/pic.jpg")
    );
    let plain = "<html><head><title>\n  A &amp; B &#8212; Docs\n</title></head>";
    let meta = page_meta(plain, &page);
    assert_eq!(meta.title.as_deref(), Some("A & B — Docs"));
    assert_eq!(meta.site.as_deref(), Some("example.com"));
    assert_eq!(meta.image, None);
    assert_eq!(title_tag("<title></title>"), None);
    assert_eq!(strip_site("Docs | Example", Some("Example")), "Docs");
    assert_eq!(strip_site("Example — Docs", Some("Example")), "Docs");
    assert_eq!(strip_site("Docs", None), "Docs");
    let long = format!("<title>{}</title>", "t".repeat(400));
    let title = page_meta(&long, &page).title.unwrap();
    assert_eq!(title.chars().count(), 300);
}

// MARK: the picture

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

#[test]
fn the_picture_is_a_small_jpeg() {
    let picture = to_jpeg(&png(2400, 1200)).expect("a readable PNG");
    assert!(picture.jpeg.len() as u64 <= cmux_conversation::MAX_PREVIEW_IMAGE_BYTES);
    assert_eq!(&picture.jpeg[..3], &[0xff, 0xd8, 0xff]);
    assert_eq!((picture.width, picture.height), (1200, 600));
    let small = to_jpeg(&png(64, 32)).unwrap();
    assert_eq!((small.width, small.height), (64, 32));
    assert_eq!(to_jpeg(b"not an image"), None);
    assert_eq!(
        to_jpeg(br#"<svg xmlns="http://www.w3.org/2000/svg"></svg>"#),
        None
    );
}

// MARK: fetching

#[test]
fn the_http_fetcher_reads_the_page_then_its_image() {
    let image = png(300, 200);
    let table = Table::new(vec![
        (
            "https://www.github.com/manaflow-ai/cmux",
            Hop::Body(PAGE.as_bytes().to_vec()),
        ),
        (
            "https://www.github.com/img/card.png?v=1&s=2",
            Hop::Body(image),
        ),
    ]);
    let fetcher = HttpFetcher::with_transport(Arc::new(table));
    let fetched = fetcher
        .fetch("https://www.github.com/manaflow-ai/cmux", soon())
        .unwrap();
    assert_eq!(
        fetched.title.as_deref(),
        Some("manaflow-ai/cmux: A terminal & more")
    );
    assert_eq!(fetched.site.as_deref(), Some("github.com"));
    let picture = fetched.picture.expect("the og:image");
    assert_eq!((picture.width, picture.height), (300, 200));
    let private = HttpFetcher::with_transport(Arc::new(Table::new(Vec::new())));
    assert_eq!(private.fetch("http://127.0.0.1/", soon()), None);
}

struct Slow(Duration);

impl Fetcher for Slow {
    fn fetch(&self, url: &str, _: Instant) -> Option<Fetched> {
        if url.contains("slow") {
            std::thread::sleep(self.0);
        }
        Some(Fetched {
            title: Some(url.to_owned()),
            ..Fetched::default()
        })
    }
}

#[test]
fn previews_are_fetched_at_once_and_a_late_one_is_left_out() {
    let started = Instant::now();
    let fetched = fetch_all(
        Arc::new(Slow(Duration::from_secs(5))),
        vec![
            (0, "https://example.com/slow".into()),
            (2, "https://example.com/a".into()),
            (4, "https://example.com/b".into()),
        ],
        Duration::from_millis(300),
    );
    assert!(
        started.elapsed() < Duration::from_secs(2),
        "bounded by the timeout"
    );
    let indexes: Vec<usize> = fetched.iter().map(|(i, _)| *i).collect();
    assert_eq!(indexes, vec![2, 4]);
}

// MARK: a reply with a card

/// A fetcher that answers every URL from memory (no network).
struct Canned(Option<Fetched>);

impl Fetcher for Canned {
    fn fetch(&self, _: &str, _: Instant) -> Option<Fetched> {
        self.0.clone()
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

#[test]
fn a_reply_with_a_url_line_goes_as_text_then_a_filled_card() {
    let mut h = Harness::new(reply_script("Here it is:\nhttps://example.com/x"));
    let jpeg = to_jpeg(&png(120, 60)).unwrap().jpeg;
    h.brain.set_previewer(Arc::new(Canned(Some(Fetched {
        title: Some("Example X".into()),
        site: Some("example.com".into()),
        picture: Some(Picture {
            jpeg: jpeg.clone(),
            width: 120,
            height: 60,
        }),
    }))));
    h.connect();
    h.say("user_local", "send me the link");
    h.settle();
    let parts = sent_reply(&mut h);
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
    assert!(
        cmux_conversation::valid_link_preview_part(&parts[1]),
        "the owner's shape rules hold"
    );
}

#[test]
fn a_failed_fetch_sends_the_card_with_its_url_only() {
    let mut h = Harness::new(reply_script("Here it is:\nhttps://example.com/x"));
    h.brain.set_previewer(Arc::new(Canned(None)));
    h.connect();
    h.say("user_local", "send me the link");
    h.settle();
    assert_eq!(
        sent_reply(&mut h),
        vec![text("Here it is:"), card("https://example.com/x")]
    );
    assert!(h.owner.lock().unwrap().uploads.is_empty());
}
