//! A preview picture: the page's image decoded (JPEG, PNG, GIF or WebP
//! only, with decoder limits), scaled down and encoded as a JPEG of at most
//! [`MAX_PREVIEW_IMAGE_BYTES`] (the owner's cap on a link preview image).
//! Transparent pixels go on white, as a card shows them.

use std::io::Cursor;

use cmux_conversation::MAX_PREVIEW_IMAGE_BYTES;
use image::imageops::FilterType;
use image::{DynamicImage, ImageFormat, ImageReader, Limits, RgbImage};

/// A JPEG ready to upload.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Picture {
    pub jpeg: Vec<u8>,
    pub width: u32,
    pub height: u32,
}

/// Longest side and quality of each try, largest first.
const TRIES: [(u32, u8); 5] = [(1200, 82), (900, 78), (600, 74), (400, 68), (300, 60)];

/// `bytes` as a preview JPEG, or None when they are not a readable image.
pub fn to_jpeg(bytes: &[u8]) -> Option<Picture> {
    let mut reader = ImageReader::new(Cursor::new(bytes))
        .with_guessed_format()
        .ok()?;
    if !matches!(
        reader.format(),
        Some(ImageFormat::Jpeg | ImageFormat::Png | ImageFormat::Gif | ImageFormat::WebP)
    ) {
        return None;
    }
    let mut limits = Limits::default();
    limits.max_image_width = Some(12_000);
    limits.max_image_height = Some(12_000);
    limits.max_alloc = Some(256 * 1024 * 1024);
    reader.limits(limits);
    let image = reader.decode().ok()?;
    let rgb = on_white(&image);
    for (side, quality) in TRIES {
        let scaled = if rgb.width().max(rgb.height()) > side {
            DynamicImage::ImageRgb8(rgb.clone())
                .resize(side, side, FilterType::Triangle)
                .to_rgb8()
        } else {
            rgb.clone()
        };
        let mut jpeg = Vec::new();
        let mut encoder = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut jpeg, quality);
        encoder
            .encode(
                scaled.as_raw(),
                scaled.width(),
                scaled.height(),
                image::ExtendedColorType::Rgb8,
            )
            .ok()?;
        if !jpeg.is_empty() && jpeg.len() as u64 <= MAX_PREVIEW_IMAGE_BYTES {
            return Some(Picture {
                jpeg,
                width: scaled.width(),
                height: scaled.height(),
            });
        }
    }
    None
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
