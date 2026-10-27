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

/// Largest original this decodes. This is a decoder safety budget for generated model previews,
/// not a cap on the original attachment, which remains available to the owner.
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
    let small = if image.width().max(image.height()) > edge {
        // Box-filtered: fast on a 16 MP screenshot, sharp enough for text.
        image.thumbnail(edge, edge)
    } else {
        image.clone()
    };
    on_white(&small)
}

/// The image as RGB, transparent pixels blended onto white.
fn on_white(image: &DynamicImage) -> RgbImage {
    if !image.color().has_alpha() {
        return image.to_rgb8();
    }
    let rgba = image.to_rgba8();
    RgbImage::from_fn(rgba.width(), rgba.height(), |x, y| {
        let [r, g, b, a] = rgba.get_pixel(x, y).0;
        let blend = |c: u8| ((c as u32 * a as u32 + 255 * (255 - a as u32)) / 255) as u8;
        image::Rgb([blend(r), blend(g), blend(b)])
    })
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

    #[test]
    fn not_an_image_says_why() {
        let why = fit(b"%PDF-1.7 not an image", 3_750_000).unwrap_err();
        assert!(!why.is_empty());
    }
}
