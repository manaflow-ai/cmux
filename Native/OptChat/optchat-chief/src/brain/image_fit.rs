//! A turn image too large for the model, made small enough: decoded (JPEG,
//! PNG, GIF or WebP, with decoder limits), scaled to at most [`MAX_EDGE`]
//! on its long edge and encoded as a JPEG under the Messages API's byte
//! limit. Transparent pixels go on white (a macOS window screenshot has a
//! transparent shadow). The original stays with the owner untouched.

use std::io::Cursor;

use image::{DynamicImage, ImageFormat, ImageReader, Limits, RgbImage};

/// Longest side sent to the model. The API scales anything above ~1568 px
/// down itself, so a larger copy only costs bytes; 2000 px keeps small text
/// of a Retina screenshot legible after that scaling.
pub const MAX_EDGE: u32 = 2000;

/// Largest original this decodes: Home's upload cap (`HomeAttachmentPolicy.maxBytes`),
/// so every image a person can attach gets a copy. A 6K Retina screenshot
/// PNG is 10-30 MB; a busy one can be ~65 MB.
pub const MAX_SOURCE_BYTES: u64 = 100_000_000;
/// Widest and tallest image decoded (keeps a decompression bomb out).
pub const MAX_SIDE: u32 = 16_384;
/// Most memory the decoder may take (a 16384 px square RGBA is 1 GiB; a
/// 6K screenshot is ~70 MB).
pub const MAX_ALLOC: u64 = 512 * 1024 * 1024;

/// Long edge and JPEG quality of each try, best first.
const TRIES: [(u32, u8); 5] = [
    (MAX_EDGE, 85),
    (MAX_EDGE, 72),
    (1568, 72),
    (1200, 66),
    (800, 60),
];

/// A JPEG the model reads.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Fitted {
    pub jpeg: Vec<u8>,
    pub width: u32,
    pub height: u32,
}

/// `bytes` as a JPEG of at most [`MAX_EDGE`] px and `max_bytes`, or why not.
pub fn fit(bytes: &[u8], max_bytes: u64) -> Result<Fitted, String> {
    let mut reader = ImageReader::new(Cursor::new(bytes))
        .with_guessed_format()
        .map_err(|e| format!("unknown image format: {e}"))?;
    match reader.format() {
        Some(ImageFormat::Jpeg | ImageFormat::Png | ImageFormat::Gif | ImageFormat::WebP) => {}
        Some(other) => return Err(format!("cannot decode {other:?}")),
        None => return Err("unknown image format".into()),
    }
    let mut limits = Limits::default();
    limits.max_image_width = Some(MAX_SIDE);
    limits.max_image_height = Some(MAX_SIDE);
    limits.max_alloc = Some(MAX_ALLOC);
    reader.limits(limits);
    let image = reader.decode().map_err(|e| format!("decode failed: {e}"))?;
    for (edge, quality) in TRIES {
        let rgb = scaled(&image, edge);
        let mut jpeg = Vec::new();
        image::codecs::jpeg::JpegEncoder::new_with_quality(&mut jpeg, quality)
            .encode(
                rgb.as_raw(),
                rgb.width(),
                rgb.height(),
                image::ExtendedColorType::Rgb8,
            )
            .map_err(|e| format!("encode failed: {e}"))?;
        if !jpeg.is_empty() && jpeg.len() as u64 <= max_bytes {
            return Ok(Fitted {
                jpeg,
                width: rgb.width(),
                height: rgb.height(),
            });
        }
    }
    Err(format!("no copy fits in {max_bytes} bytes"))
}

/// The image at most `edge` px on its long side, as RGB on white.
fn scaled(image: &DynamicImage, edge: u32) -> RgbImage {
    let (width, height) = (image.width(), image.height());
    if width.max(height) <= edge {
        return on_white(image);
    }
    // Area-averaged in linear light (cmux_image_linear), a row at a time: fast on a 16 MP
    // screenshot, and text keeps its weight instead of going darker.
    let (out_w, out_h) = cmux_image_linear::fit(width, height, edge);
    let mut scaler = cmux_image_linear::Downscaler::new(width, height, out_w, out_h, false);
    let mut push = |raw: &[u8], channels: usize| {
        for row in raw.chunks_exact(width as usize * channels) {
            scaler.push_row(row.chunks_exact(channels).map(|px| match px {
                [r, g, b] => [*r, *g, *b, 255],
                [r, g, b, a] => {
                    let [r, g, b] = blend_on_white([*r, *g, *b, *a]);
                    [r, g, b, 255]
                }
                _ => [0; 4],
            }));
        }
    };
    match image {
        DynamicImage::ImageRgb8(rgb) => push(rgb.as_raw(), 3),
        DynamicImage::ImageRgba8(rgba) => push(rgba.as_raw(), 4),
        other => push(other.to_rgba8().as_raw(), 4),
    }
    // `finish` gives exactly `out_w * out_h` RGB pixels.
    RgbImage::from_raw(out_w, out_h, scaler.finish()).unwrap_or_default()
}

/// The image as RGB, transparent pixels blended onto white.
fn on_white(image: &DynamicImage) -> RgbImage {
    if !image.color().has_alpha() {
        return image.to_rgb8();
    }
    let rgba = image.to_rgba8();
    RgbImage::from_fn(rgba.width(), rgba.height(), |x, y| {
        image::Rgb(blend_on_white(rgba.get_pixel(x, y).0))
    })
}

/// One pixel blended onto white, as a card or the model's viewer shows it.
fn blend_on_white([r, g, b, a]: [u8; 4]) -> [u8; 3] {
    let blend = |c: u8| ((c as u32 * a as u32 + 255 * (255 - a as u32)) / 255) as u8;
    [blend(r), blend(g), blend(b)]
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use image::{Rgba, RgbaImage};

    /// A noisy PNG (hard to compress, like a busy screenshot) with a
    /// transparent border, like a macOS window capture's shadow.
    pub(crate) fn screenshot_png(width: u32, height: u32) -> Vec<u8> {
        let mut seed = 0x9e37_79b9_u32;
        let image = RgbaImage::from_fn(width, height, |x, y| {
            seed ^= seed << 13;
            seed ^= seed >> 17;
            seed ^= seed << 5;
            let border = x < 40 || y < 40 || x + 40 >= width || y + 40 >= height;
            // Four bits a channel: a PNG of ~1.5 bytes a pixel.
            let [a, b, c, _] = (seed & 0x00f0_f0f0).to_le_bytes();
            Rgba([a, b, c, if border { 0 } else { 255 }])
        });
        let mut png = Vec::new();
        DynamicImage::ImageRgba8(image)
            .write_to(&mut Cursor::new(&mut png), ImageFormat::Png)
            .unwrap();
        png
    }

    #[test]
    fn a_6k_retina_screenshot_fits_the_model() {
        let png = screenshot_png(5344, 3044);
        assert!(png.len() as u64 > crate::brain::images::MAX_ORIGINAL_BYTES);
        let fitted = fit(&png, crate::brain::images::MAX_ORIGINAL_BYTES).unwrap();
        assert!(fitted.jpeg.len() as u64 <= crate::brain::images::MAX_ORIGINAL_BYTES);
        assert_eq!(fitted.width.max(fitted.height), MAX_EDGE);
        assert!((1139..=1140).contains(&fitted.height), "{}", fitted.height);
        let back = image::load_from_memory(&fitted.jpeg).unwrap();
        assert_eq!((back.width(), back.height()), (fitted.width, fitted.height));
        // The transparent shadow came out white, not black.
        let corner = back.to_rgb8().get_pixel(0, 0).0;
        assert!(corner.iter().all(|&c| c > 240), "{corner:?}");
    }

    #[test]
    fn a_tall_image_keeps_its_aspect() {
        let png = screenshot_png(600, 4000);
        let fitted = fit(&png, 3_750_000).unwrap();
        assert_eq!((fitted.width, fitted.height), (300, 2000));
    }

    #[test]
    fn a_tight_byte_limit_steps_down_size_and_quality() {
        let png = screenshot_png(3000, 2000);
        let best = fit(&png, u64::MAX).unwrap();
        let limit = best.jpeg.len() as u64 - 1;
        let fitted = fit(&png, limit).unwrap();
        assert!(fitted.jpeg.len() as u64 <= limit);
    }

    /// A `n`x`n` PNG of 1 px black and white: a checkerboard, or alternating rows.
    fn black_and_white_png(n: u32, checker: bool) -> Vec<u8> {
        let image = image::GrayImage::from_fn(n, n, |x, y| {
            let on = if checker {
                (x + y) % 2 == 0
            } else {
                y % 2 == 0
            };
            image::Luma([if on { 255 } else { 0 }])
        });
        let mut png = Vec::new();
        DynamicImage::ImageLuma8(image)
            .write_to(&mut Cursor::new(&mut png), ImageFormat::Png)
            .unwrap();
        png
    }

    /// The mean of a decoded JPEG's middle half, one channel.
    fn middle_mean(jpeg: &[u8]) -> f64 {
        let rgb = image::load_from_memory(jpeg).unwrap().to_rgb8();
        let (w, h) = rgb.dimensions();
        let (mut sum, mut n) = (0u64, 0u64);
        for y in h / 4..3 * h / 4 {
            for x in w / 4..3 * w / 4 {
                sum += u64::from(rgb.get_pixel(x, y)[1]);
                n += 1;
            }
        }
        sum as f64 / n as f64
    }

    /// Fine black and white detail (a screenshot's text and lines) keeps its light: half
    /// black, half white is 188, not the 128 an average of sRGB codes gives
    /// ("What every coder should know about gamma").
    #[test]
    fn a_model_copy_averages_light_not_srgb_codes() {
        for checker in [true, false] {
            for n in [MAX_EDGE * 2, MAX_EDGE * 4] {
                let fitted = fit(&black_and_white_png(n, checker), u64::MAX).unwrap();
                assert_eq!(fitted.width, MAX_EDGE);
                let mean = middle_mean(&fitted.jpeg);
                assert!(
                    (185.0..=191.0).contains(&mean),
                    "checker {checker} {n}: {mean}"
                );
            }
        }
    }

    /// Before and after, one harness: the `image` crate's box thumbnail (the model copy
    /// before) and triangle resize (the link preview picture before), both averaging sRGB
    /// codes, against the linear-light area average now, on a 6K screenshot.
    /// Run: `cargo test --release -p optchat-chief before_and_after_timing -- --ignored --nocapture`.
    #[test]
    #[ignore = "timing; run by hand"]
    fn before_and_after_timing() {
        let image = image::load_from_memory(&screenshot_png(5344, 3044)).unwrap();
        let best = |f: &dyn Fn() -> RgbImage| {
            (0..5)
                .map(|_| {
                    let t = std::time::Instant::now();
                    std::hint::black_box(f());
                    t.elapsed().as_secs_f64() * 1000.0
                })
                .fold(f64::INFINITY, f64::min)
        };
        let rgb = on_white(&image);
        let (w, h) = cmux_image_linear::fit(5344, 3044, MAX_EDGE);
        // gamma: allow the before reference this times
        let thumbnail = best(&|| on_white(&image.thumbnail(MAX_EDGE, MAX_EDGE)));
        let triangle = best(&|| {
            // gamma: allow the before reference this times
            image::imageops::resize(&rgb, w, h, image::imageops::FilterType::Triangle)
        });
        let linear = best(&|| scaled(&image, MAX_EDGE));
        println!(
            "5344x3044 -> {w}x{h}, best of 5: thumbnail (sRGB) {thumbnail:.1} ms, \
             triangle (sRGB) {triangle:.1} ms, linear area {linear:.1} ms"
        );
    }

    #[test]
    fn not_an_image_says_why() {
        let why = fit(b"%PDF-1.7 not an image", 3_750_000).unwrap_err();
        assert!(!why.is_empty());
    }
}
