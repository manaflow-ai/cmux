use super::*;

/// A `w`x`h` RGBA PNG of noise, which compresses badly, so a large one is past the cap.
fn noise_png(w: u32, h: u32) -> Vec<u8> {
    let mut seed = 0x2545_f491_u32;
    let pixels: Vec<u8> = (0..w * h * 4)
        .map(|_| {
            seed = seed.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
            (seed >> 24) as u8
        })
        .collect();
    let mut bytes = Vec::new();
    let mut encoder = png::Encoder::new(&mut bytes, w, h);
    encoder.set_color(png::ColorType::Rgba);
    encoder.set_depth(png::BitDepth::Eight);
    let mut writer = encoder.write_header().unwrap();
    writer.write_image_data(&pixels).unwrap();
    writer.finish().unwrap();
    bytes
}

/// An ICO of `frames`, each (edge in px, its bytes), laid out after the directory.
fn ico(frames: &[(u8, Vec<u8>)]) -> Vec<u8> {
    let mut out = vec![0, 0, 1, 0];
    out.extend_from_slice(&(frames.len() as u16).to_le_bytes());
    let mut offset = 6 + 16 * frames.len();
    for (edge, bytes) in frames {
        out.extend_from_slice(&[*edge, *edge, 0, 0, 1, 0, 32, 0]);
        out.extend_from_slice(&(bytes.len() as u32).to_le_bytes());
        out.extend_from_slice(&(offset as u32).to_le_bytes());
        offset += bytes.len();
    }
    for (_, bytes) in frames {
        out.extend_from_slice(bytes);
    }
    out
}

/// A bitmap frame's bytes: a DIB header and nothing a PNG starts with.
fn bitmap(len: usize) -> Vec<u8> {
    let mut b = vec![0x28, 0, 0, 0];
    b.resize(len, 0xAB);
    b
}

#[test]
fn an_image_that_fits_is_sent_as_it_is() {
    let small = bitmap(100);
    assert_eq!(fit("image/x-icon", small.clone()).unwrap(), ("image/x-icon", small));
}

#[test]
fn a_two_frame_bitmap_ico_past_the_cap_keeps_its_larger_frame_that_fits() {
    // The shape of github.com's favicon: 16 px (1320 bytes) and 32 px (5160 bytes) bitmaps.
    let (small, large) = (bitmap(1320), bitmap(5160));
    let whole = ico(&[(16, small), (32, large.clone())]);
    assert!(whole.len() > MAX_IMAGE_BYTES);
    let (mime, made) = fit("image/x-icon", whole).unwrap();
    assert_eq!(mime, "image/x-icon");
    assert_eq!(made.len(), 22 + large.len());
    let frame = frames(&made);
    assert_eq!(frame.len(), 1);
    assert_eq!((frame[0].edge, frame[0].bytes), (32, large.as_slice()));
    crate::session_icon::SessionIcon::image(mime, &made).unwrap();
}

#[test]
fn an_ico_with_a_png_frame_that_fits_sends_that_png() {
    let png = noise_png(16, 16);
    let whole = ico(&[(16, png.clone()), (0, bitmap(MAX_IMAGE_BYTES + 10))]);
    assert_eq!(fit("image/x-icon", whole).unwrap(), ("image/png", png));
}

#[test]
fn an_ico_of_one_large_png_frame_is_scaled_down() {
    // The shape of news.ycombinator.com's favicon: one 256 px PNG frame past the cap.
    let png = noise_png(256, 256);
    assert!(png.len() > MAX_IMAGE_BYTES);
    let (mime, made) = fit("image/x-icon", ico(&[(0, png)])).unwrap();
    assert_eq!(mime, "image/png");
    assert!(made.len() <= MAX_IMAGE_BYTES, "{} bytes", made.len());
    crate::session_icon::SessionIcon::image(mime, &made).unwrap();
    // Not marked as a model copy: an icon is no copy of a chat image.
    assert!(!made.windows(6).any(|w| w == b"acpmux"));
}

#[test]
fn a_large_png_is_scaled_down() {
    let png = noise_png(512, 512);
    let (mime, made) = fit("image/png", png).unwrap();
    assert_eq!(mime, "image/png");
    assert!(made.len() <= MAX_IMAGE_BYTES);
    let decoder = png::Decoder::new(std::io::Cursor::new(&made));
    let info = decoder.read_info().unwrap();
    assert!(info.info().width <= 128 && info.info().width >= 16);
}

#[test]
fn an_svg_past_the_cap_is_refused_with_what_to_give() {
    let svg = format!("<svg>{}</svg>", " ".repeat(MAX_IMAGE_BYTES)).into_bytes();
    let why = fit("image/svg+xml", svg).unwrap_err().to_string();
    assert!(why.contains("give a PNG, an ICO or a small SVG"), "{why}");
}

#[test]
fn a_broken_ico_is_refused() {
    let mut whole = ico(&[(32, bitmap(MAX_IMAGE_BYTES + 100))]);
    whole.truncate(MAX_IMAGE_BYTES + 50);
    assert!(fit("image/x-icon", whole).is_err());
}

#[test]
fn icon_links_reads_rel_icon_tags_svg_first() {
    let html = r#"<html><head>
        <link rel="stylesheet" href="/site.css">
        <LINK REL="shortcut icon" HREF="/static/favicon-32.png?v=2">
        <link href='/logo.svg' rel='icon' type='image/svg+xml'>
        <link rel=apple-touch-icon href=/touch.png>
        <link rel="icon" href="https://cdn.example.org/a.ico?x=1&amp;y=2" />
        <link rel="icon" href="">
        <link rel="preload icons" href="/no.png">
    </head></html>"#;
    assert_eq!(
        icon_links(html),
        vec![
            "/logo.svg",
            "/static/favicon-32.png?v=2",
            "/touch.png",
            "https://cdn.example.org/a.ico?x=1&y=2",
        ]
    );
}

#[test]
fn icon_links_of_a_page_without_icons_is_empty() {
    assert!(icon_links("<html><link rel=stylesheet href=a.css>").is_empty());
    assert!(icon_links("not html at all <link").is_empty());
}
