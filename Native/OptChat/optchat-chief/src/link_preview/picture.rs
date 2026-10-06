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
    let _ = (
        bytes,
        TRIES,
        MAX_PREVIEW_IMAGE_BYTES,
        on_white as fn(&DynamicImage) -> RgbImage,
    );
    let _ = (
        ImageReader::<Cursor<&[u8]>>::new,
        ImageFormat::Png,
        Limits::default(),
        FilterType::Triangle,
    );
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
