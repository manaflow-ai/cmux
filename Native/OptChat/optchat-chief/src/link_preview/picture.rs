//! A preview picture: the page's image decoded (JPEG, PNG, GIF or WebP
//! only, with decoder limits), scaled down and encoded as a JPEG of at most
//! [`MAX_PREVIEW_IMAGE_BYTES`] (the owner's cap on a link preview image).
//! Transparent pixels go on white, as a card shows them.

use std::io::Cursor;
use std::sync::{Condvar, Mutex, PoisonError};
use std::time::Instant;

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

/// Widest and tallest image decoded: a page's card image is far smaller,
/// and the cap keeps a decompression bomb from reaching the allocator.
pub const MAX_SIDE: u32 = 4096;
/// Most memory the decoder may take.
pub const MAX_ALLOC: u64 = 64 * 1024 * 1024;

/// `bytes` as a preview JPEG, or None when they are not a readable image
/// within [`MAX_SIDE`] and [`MAX_ALLOC`], or `deadline` passes first (it is
/// checked before the decode and before each encode try).
pub fn to_jpeg(bytes: &[u8], deadline: Instant) -> Option<Picture> {
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
    limits.max_image_width = Some(MAX_SIDE);
    limits.max_image_height = Some(MAX_SIDE);
    limits.max_alloc = Some(MAX_ALLOC);
    reader.limits(limits);
    // At most two decodes at once across every preview thread (a decode
    // takes up to MAX_ALLOC of memory); a turn waits for its slot only
    // until the deadline.
    let _slot = DecodeSlot::take(deadline)?;
    let image = reader.decode().ok()?;
    let rgb = on_white(&image);
    drop(image);
    for (side, quality) in TRIES {
        if Instant::now() >= deadline {
            return None;
        }
        // Scaled from the one decoded image each time; never copied whole.
        let scaled;
        let shown: &RgbImage = if rgb.width().max(rgb.height()) > side {
            let (width, height) = fit(rgb.width(), rgb.height(), side);
            scaled = image::imageops::resize(&rgb, width, height, FilterType::Triangle);
            &scaled
        } else {
            &rgb
        };
        let mut jpeg = Vec::new();
        let mut encoder = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut jpeg, quality);
        encoder
            .encode(
                shown.as_raw(),
                shown.width(),
                shown.height(),
                image::ExtendedColorType::Rgb8,
            )
            .ok()?;
        if !jpeg.is_empty() && jpeg.len() as u64 <= MAX_PREVIEW_IMAGE_BYTES {
            return Some(Picture {
                jpeg,
                width: shown.width(),
                height: shown.height(),
            });
        }
    }
    None
}

/// Most picture decodes at once.
pub const MAX_DECODES: usize = 2;

static DECODES: (Mutex<usize>, Condvar) = (Mutex::new(0), Condvar::new());

/// One of the [`MAX_DECODES`] decode slots, given back on drop.
struct DecodeSlot;

impl DecodeSlot {
    /// A slot, or None when `deadline` passes first.
    fn take(deadline: Instant) -> Option<DecodeSlot> {
        let (count, freed) = &DECODES;
        let mut running = count.lock().unwrap_or_else(PoisonError::into_inner);
        while *running >= MAX_DECODES {
            let left = deadline.checked_duration_since(Instant::now())?;
            running = freed
                .wait_timeout(running, left)
                .unwrap_or_else(PoisonError::into_inner)
                .0;
        }
        if Instant::now() >= deadline {
            return None;
        }
        *running += 1;
        Some(DecodeSlot)
    }
}

impl Drop for DecodeSlot {
    fn drop(&mut self) {
        let (count, freed) = &DECODES;
        let mut running = count.lock().unwrap_or_else(PoisonError::into_inner);
        *running = running.saturating_sub(1);
        freed.notify_one();
    }
}

/// `width` x `height` scaled to fit a `side` square, aspect kept, at least 1.
fn fit(width: u32, height: u32, side: u32) -> (u32, u32) {
    let longest = width.max(height).max(1) as u64;
    let scale = |v: u32| ((v as u64 * side as u64 / longest) as u32).max(1);
    (scale(width), scale(height))
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
mod tests {
    use super::*;
    use image::GrayImage;

    fn black_and_white_png(n: u32, checker: bool) -> Vec<u8> {
        let image = GrayImage::from_fn(n, n, |x, y| {
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

    fn middle_mean(jpeg: &[u8]) -> f64 {
        let rgb = image::load_from_memory(jpeg).unwrap().to_rgb8();
        let (w, h) = rgb.dimensions();
        let middle: Vec<u64> = (h / 4..3 * h / 4)
            .flat_map(|y| (w / 4..3 * w / 4).map(move |x| (x, y)))
            .map(|(x, y)| u64::from(rgb.get_pixel(x, y)[1]))
            .collect();
        middle.iter().sum::<u64>() as f64 / middle.len() as f64
    }

    /// A card picture's fine black and white detail keeps its light: half black, half
    /// white is 188, not the 128 an average of sRGB codes gives
    /// ("What every coder should know about gamma").
    #[test]
    fn a_preview_picture_averages_light_not_srgb_codes() {
        for checker in [true, false] {
            for n in [2400] {
                let deadline = Instant::now() + std::time::Duration::from_secs(60);
                let picture = to_jpeg(&black_and_white_png(n, checker), deadline).unwrap();
                assert_eq!(picture.width, 1200);
                let mean = middle_mean(&picture.jpeg);
                assert!(
                    (185.0..=191.0).contains(&mean),
                    "checker {checker} {n}: {mean}"
                );
            }
        }
    }
}
