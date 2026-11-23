//! An image's pixel size, read from its header only (no decode), so a record or a row that names
//! an image carries its size and the chat reserves its exact box before the bytes arrive: a
//! decoded image never changes a row's height (design: agent-transcript-clean-slate.md, step 2,
//! "It supplies image sizes, so a decoded image never changes height").
//! PNG, GIF, JPEG and WebP (VP8, VP8L, VP8X). Anything else, or a cut-short header, is `None`,
//! and the record names the image as before. The v1 hub reads a prompt image's bytes with
//! [`image_dims`]; the book's translator reads an inline base64 image with [`base64_image_dims`].

/// Largest side a header may claim and still be believed. A header claiming more is not an image
/// the chat can draw; the record leaves the size out rather than reserve a giant box.
const MAX_SIDE: u32 = 1 << 16;

/// `(width, height)` in pixels from the image's header, or `None`.
pub fn image_dims(bytes: &[u8]) -> Option<(u32, u32)> {
    let dims = png(bytes).or_else(|| gif(bytes)).or_else(|| jpeg(bytes)).or_else(|| webp(bytes))?;
    let sane = |side: u32| side > 0 && side <= MAX_SIDE;
    (sane(dims.0) && sane(dims.1)).then_some(dims)
}

/// The most bytes of an image's start [`base64_image_dims`] decodes: a PNG, GIF or WebP header
/// is in its first 30 bytes, and a JPEG's frame header comes after its APP segments (EXIF, ICC),
/// which a camera can make tens of KB. So a line's cost is bounded whatever the image's size.
pub const MAX_HEADER_BYTES: usize = 256 * 1024;

/// `(width, height)` of an image given as standard base64 (an inline `source.data` or a data URL's
/// payload), decoding at most [`MAX_HEADER_BYTES`] of its start: first 4 KB, which holds every
/// header but a JPEG's with large APP segments, then the bound. `None` as for [`image_dims`], and
/// for text that is not base64.
pub fn base64_image_dims(data: &str) -> Option<(u32, u32)> {
    let mut bytes = Vec::new();
    for cap in [4 * 1024, MAX_HEADER_BYTES] {
        decode_prefix(data.as_bytes(), cap, &mut bytes)?;
        let dims = image_dims(&bytes);
        // A short image decodes whole at the first cap; reading again would give the same.
        if dims.is_some() || bytes.len() < cap {
            return dims;
        }
    }
    None
}

/// Decodes standard base64 (padding optional) into `out`, stopping once `out` holds `cap` bytes
/// or the text ends. `None` at a character that is not base64.
fn decode_prefix(text: &[u8], cap: usize, out: &mut Vec<u8>) -> Option<()> {
    out.clear();
    let (mut acc, mut bits) = (0u32, 0u32);
    for &c in text {
        if out.len() >= cap {
            break;
        }
        let v = match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            b'=' => break,
            _ => return None,
        };
        acc = (acc << 6) | u32::from(v);
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
            acc &= (1 << bits) - 1;
        }
    }
    Some(())
}

fn be32(bytes: &[u8], at: usize) -> Option<u32> {
    Some(u32::from_be_bytes(bytes.get(at..at + 4)?.try_into().ok()?))
}

fn be16(bytes: &[u8], at: usize) -> Option<u32> {
    Some(u32::from(u16::from_be_bytes(bytes.get(at..at + 2)?.try_into().ok()?)))
}

fn le16(bytes: &[u8], at: usize) -> Option<u32> {
    Some(u32::from(u16::from_le_bytes(bytes.get(at..at + 2)?.try_into().ok()?)))
}

fn le24(bytes: &[u8], at: usize) -> Option<u32> {
    let [b0, b1, b2]: [u8; 3] = bytes.get(at..at + 3)?.try_into().ok()?;
    Some(u32::from(b0) | u32::from(b1) << 8 | u32::from(b2) << 16)
}

/// The IHDR chunk is first: width and height at bytes 16..24.
fn png(bytes: &[u8]) -> Option<(u32, u32)> {
    if !bytes.starts_with(b"\x89PNG\r\n\x1a\n") || bytes.get(12..16)? != b"IHDR" {
        return None;
    }
    Some((be32(bytes, 16)?, be32(bytes, 20)?))
}

/// The logical screen size, little-endian, after the six-byte signature.
fn gif(bytes: &[u8]) -> Option<(u32, u32)> {
    if !(bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a")) {
        return None;
    }
    Some((le16(bytes, 6)?, le16(bytes, 8)?))
}

/// The first start-of-frame marker (SOF0..SOF15, not DHT, JPG or DAC) holds height then width.
/// Segments are walked by their lengths, so a large EXIF block is skipped, never scanned.
fn jpeg(bytes: &[u8]) -> Option<(u32, u32)> {
    if !bytes.starts_with(&[0xFF, 0xD8]) {
        return None;
    }
    let mut at = 2;
    loop {
        // Fill bytes (0xFF runs) may precede a marker.
        while *bytes.get(at)? == 0xFF && *bytes.get(at + 1)? == 0xFF {
            at += 1;
        }
        if *bytes.get(at)? != 0xFF {
            return None;
        }
        let marker = *bytes.get(at + 1)?;
        // Standalone markers carry no length.
        if marker == 0x01 || (0xD0..=0xD7).contains(&marker) {
            at += 2;
            continue;
        }
        if marker == 0xD9 || marker == 0xDA {
            return None;
        }
        let len = usize::try_from(be16(bytes, at + 2)?).ok()?;
        if len < 2 {
            return None;
        }
        let is_sof = (0xC0..=0xCF).contains(&marker) && !matches!(marker, 0xC4 | 0xC8 | 0xCC);
        if is_sof {
            return Some((be16(bytes, at + 7)?, be16(bytes, at + 5)?));
        }
        at += 2 + len;
    }
}

/// RIFF/WEBP: the first chunk is VP8 (lossy), VP8L (lossless) or VP8X (extended).
fn webp(bytes: &[u8]) -> Option<(u32, u32)> {
    if bytes.get(0..4)? != b"RIFF" || bytes.get(8..12)? != b"WEBP" {
        return None;
    }
    match bytes.get(12..16)? {
        b"VP8 " => {
            // Frame tag (3 bytes), start code 9d 01 2a, then 14-bit width and height.
            if bytes.get(23..26)? != [0x9D, 0x01, 0x2A] {
                return None;
            }
            Some((le16(bytes, 26)? & 0x3FFF, le16(bytes, 28)? & 0x3FFF))
        }
        b"VP8L" => {
            if *bytes.get(20)? != 0x2F {
                return None;
            }
            let b = bytes.get(21..25)?;
            let bits = u32::from_le_bytes(b.try_into().ok()?);
            Some(((bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1))
        }
        b"VP8X" => Some((le24(bytes, 24)? + 1, le24(bytes, 27)? + 1)),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::{base64_image_dims, image_dims};

    /// Standard base64 with padding, the encoder the tests need.
    fn b64(bytes: &[u8]) -> String {
        const ABC: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        let mut out = String::new();
        for chunk in bytes.chunks(3) {
            let n =
                chunk.iter().enumerate().fold(0u32, |n, (i, b)| n | u32::from(*b) << (16 - 8 * i));
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
}
