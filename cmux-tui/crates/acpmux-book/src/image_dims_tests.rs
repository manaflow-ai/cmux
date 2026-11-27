use super::{base64_image_dims, image_dims};

/// Standard base64 with padding, the encoder the tests need.
fn b64(bytes: &[u8]) -> String {
    const ABC: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for chunk in bytes.chunks(3) {
        let n = chunk.iter().enumerate().fold(0u32, |n, (i, b)| n | u32::from(*b) << (16 - 8 * i));
        for i in 0..4 {
            out.push(if i <= chunk.len() {
                ABC[(n >> (18 - 6 * i) & 63) as usize] as char
            } else {
                '='
            });
        }
    }
    out
}

fn png(width: u32, height: u32) -> Vec<u8> {
    let mut bytes = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR".to_vec();
    bytes.extend(width.to_be_bytes());
    bytes.extend(height.to_be_bytes());
    bytes.extend([8, 6, 0, 0, 0]);
    bytes
}

#[test]
fn a_png_size_comes_from_its_ihdr() {
    assert_eq!(image_dims(&png(1280, 720)), Some((1280, 720)));
    // A real 1x1 PNG, as the prompt image tests send it.
    let one = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==";
    assert_eq!(base64_image_dims(one), Some((1, 1)));
}

#[test]
fn a_gif_size_is_its_logical_screen() {
    let mut gif = b"GIF89a".to_vec();
    gif.extend(300u16.to_le_bytes());
    gif.extend(200u16.to_le_bytes());
    assert_eq!(image_dims(&gif), Some((300, 200)));
}

#[test]
fn a_jpeg_size_comes_from_its_first_frame_header_past_app_segments() {
    let mut jpeg = vec![0xFF, 0xD8];
    // An APP1 (EXIF) segment of 100 bytes, skipped by its length.
    jpeg.extend([0xFF, 0xE1, 0x00, 100]);
    jpeg.extend(vec![0xAB; 98]);
    // A DHT segment (0xC4) is not a frame header.
    jpeg.extend([0xFF, 0xC4, 0x00, 0x04, 0x00, 0x00]);
    // SOF2 (progressive): length, precision, height 480, width 640.
    jpeg.extend([0xFF, 0xC2, 0x00, 0x11, 0x08, 0x01, 0xE0, 0x02, 0x80, 0x03]);
    jpeg.extend(vec![0; 9]);
    assert_eq!(image_dims(&jpeg), Some((640, 480)));
}

#[test]
fn a_webp_size_comes_from_each_chunk_kind() {
    let riff = |chunk: &[u8], body: &[u8]| {
        let mut bytes = b"RIFF\0\0\0\0WEBP".to_vec();
        bytes.extend(chunk);
        bytes.extend([0, 0, 0, 0]);
        bytes.extend(body);
        bytes
    };
    // Lossy: frame tag, start code, 14-bit sides.
    let mut lossy = vec![0, 0, 0, 0x9D, 0x01, 0x2A];
    lossy.extend(400u16.to_le_bytes());
    lossy.extend(300u16.to_le_bytes());
    assert_eq!(image_dims(&riff(b"VP8 ", &lossy)), Some((400, 300)));
    // Lossless: signature, then (width-1) and (height-1) in 14 bits each.
    let bits: u32 = (99) | (49 << 14);
    let mut lossless = vec![0x2F];
    lossless.extend(bits.to_le_bytes());
    assert_eq!(image_dims(&riff(b"VP8L", &lossless)), Some((100, 50)));
    // Extended: flags and reserved (4 bytes), then 24-bit (width-1) and (height-1).
    let extended = [0, 0, 0, 0, 0x7F, 0x07, 0x00, 0x37, 0x04, 0x00];
    assert_eq!(image_dims(&riff(b"VP8X", &extended)), Some((1920, 1080)));
}

#[test]
fn anything_else_or_a_cut_header_or_an_absurd_side_has_no_size() {
    assert_eq!(image_dims(b""), None);
    assert_eq!(image_dims(b"\x01\x02\x03"), None);
    assert_eq!(image_dims(&png(10, 10)[..20]), None);
    assert_eq!(image_dims(&png(0, 10)), None);
    assert_eq!(image_dims(&png(100_000, 10)), None);
    // A JPEG that reaches its scan before any frame header.
    assert_eq!(image_dims(&[0xFF, 0xD8, 0xFF, 0xDA, 0x00, 0x02]), None);
    assert_eq!(image_dims(&[0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]), None);
}

#[test]
fn a_base64_image_is_sized_from_its_start_alone() {
    assert_eq!(b64(&[0xFB, 0xFF, 0xBF]), "+/+/");
    assert_eq!(base64_image_dims(&b64(&png(640, 160))), Some((640, 160)));
    // Only an image's start is decoded, so what lies past it is never read.
    let mut bytes = png(1920, 1080);
    bytes.extend(vec![7; 9000]);
    let mut big = b64(&bytes)[..8192].to_string();
    big.push_str("!not base64!");
    assert_eq!(base64_image_dims(&big), Some((1920, 1080)));
    // A JPEG whose frame header is past 4 KB of EXIF is read at the second cap.
    let mut jpeg = vec![0xFF, 0xD8];
    for _ in 0..3 {
        jpeg.extend([0xFF, 0xE1, 0xFF, 0xF0]);
        jpeg.extend(vec![0xAB; 0xFFF0 - 2]);
    }
    jpeg.extend([0xFF, 0xC0, 0x00, 0x11, 0x08, 0x0F, 0xC0, 0x0B, 0xD0, 0x03]);
    jpeg.extend(vec![0; 9]);
    assert_eq!(base64_image_dims(&b64(&jpeg)), Some((3024, 4032)));
    // Text that is not base64, or an empty one, names no size.
    assert_eq!(base64_image_dims("not base64!"), None);
    assert_eq!(base64_image_dims(""), None);
}
