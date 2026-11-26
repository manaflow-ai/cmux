//! Whether a video picked on the phone is recompressed before it goes to the Mac, and whether
//! the recompressed copy is the one sent (Leo, 2026-11-24: "attachments and shit potentially
//! need to be optimistically transferred from phone to mac... and the size needs to be
//! optimized too"; his bar: "a 1-minute 4K video sends from iPhone on LTE with visible progress
//! and can be cancelled mid-send").
//!
//! Swift reads the picked file's facts (pixel size after rotation, duration, bytes), asks
//! [`video_recompress_plan`], runs AVFoundation's HEVC 1920x1080 export when told to, and asks
//! [`video_recompress_keep`] before uploading the export instead of the original. It decides
//! nothing itself. The setting that turns this on is off by default.

/// The target: HEVC at 1920x1080 (AVFoundation's `AVAssetExportPresetHEVC1920x1080`), the
/// long side and the short side at most these.
pub const TARGET_LONG_SIDE: u32 = 1920;
pub const TARGET_SHORT_SIDE: u32 = 1080;
/// A file this small goes as it is: on LTE (12 Mbit/s up) it is about 5 s, less than an
/// export of it takes.
pub const MIN_RECOMPRESS_BYTES: u64 = 8 * 1024 * 1024;
/// A video already at or under 1080p is recompressed only when its bitrate is above this
/// (the export lands near 8 Mbit/s at 1080p; a higher-bitrate 1080p source shrinks).
pub const MAX_KEEP_BITRATE: u64 = 12_000_000;
/// The export is sent only when it is at most this share of the original (per mille): a
/// copy barely smaller costs a re-encode's quality for little time.
pub const KEEP_AT_MOST_PER_MILLE: u64 = 900;

/// A picked video's facts, as the phone reads them.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct VideoSource {
    /// Displayed width and height in pixels (after the track's rotation).
    pub width: u32,
    pub height: u32,
    pub duration_ms: u64,
    pub bytes: u64,
}

/// Why a picked video is or is not recompressed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum VideoRecompressReason {
    /// The setting is off: the original goes.
    Off,
    /// Too small to be worth an export.
    Small,
    /// Already 1080p or less at a modest bitrate.
    WithinTarget,
    /// Larger than 1080p: export to HEVC 1920x1080.
    LargerThanTarget,
    /// 1080p or less but at a high bitrate: export to HEVC 1920x1080.
    HighBitrate,
    /// Facts unreadable (no size or no duration): the original goes.
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct VideoRecompressPlan {
    pub recompress: bool,
    pub reason: VideoRecompressReason,
    /// The original's bitrate in bits per second (0 when unknown), for the log line.
    pub bitrate: u64,
}

/// What to do with a picked video. `enabled` is the "Shrink videos before sending" setting.
#[uniffi::export]
#[must_use]
pub fn video_recompress_plan(enabled: bool, source: VideoSource) -> VideoRecompressPlan {
    let bitrate = if source.duration_ms == 0 {
        0
    } else {
        u64::try_from(u128::from(source.bytes) * 8 * 1000 / u128::from(source.duration_ms))
            .unwrap_or(u64::MAX)
    };
    let plan = |recompress, reason| VideoRecompressPlan { recompress, reason, bitrate };
    if !enabled {
        return plan(false, VideoRecompressReason::Off);
    }
    if source.width == 0 || source.height == 0 || source.duration_ms == 0 {
        return plan(false, VideoRecompressReason::Unknown);
    }
    if source.bytes < MIN_RECOMPRESS_BYTES {
        return plan(false, VideoRecompressReason::Small);
    }
    let long = source.width.max(source.height);
    let short = source.width.min(source.height);
    if long > TARGET_LONG_SIDE || short > TARGET_SHORT_SIDE {
        return plan(true, VideoRecompressReason::LargerThanTarget);
    }
    if bitrate > MAX_KEEP_BITRATE {
        return plan(true, VideoRecompressReason::HighBitrate);
    }
    plan(false, VideoRecompressReason::WithinTarget)
}

/// Whether the export (`output_bytes`) goes instead of the original (`source_bytes`): only
/// when it is at most [`KEEP_AT_MOST_PER_MILLE`] of it. An empty export never goes.
#[uniffi::export]
#[must_use]
pub fn video_recompress_keep(source_bytes: u64, output_bytes: u64) -> bool {
    output_bytes > 0
        && u128::from(output_bytes) * 1000 <= u128::from(source_bytes) * u128::from(KEEP_AT_MOST_PER_MILLE)
}

/// The share of a recompressed video's send bar (per mille) its export takes; the upload
/// takes the rest. Set from the 1-minute 4K estimate (an export of tens of seconds against an
/// LTE upload of about 90 s); the measured export time replaces it.
pub const EXPORT_SHARE_PER_MILLE: u64 = 300;

/// Which part of a video's send the phone is in, for [`video_send_fraction`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum VideoSendStage {
    /// No export in this send: the bar is the upload's bytes alone.
    Upload,
    /// The export is running: `export_fraction` of it is done.
    Exporting,
    /// The export finished (or was not kept): the upload of `sent` of `total` bytes.
    UploadAfterExport,
}

/// The pending bubble's one bar for a video's send, 0 to 1: the export fills the first
/// [`EXPORT_SHARE_PER_MILLE`], the upload's bytes the rest, so the bar only moves forward
/// from pick to sent (Leo: "with visible progress and can be cancelled mid-send").
#[uniffi::export]
#[must_use]
pub fn video_send_fraction(stage: VideoSendStage, export_fraction: f64, sent: u64, total: u64) -> f64 {
    let share = EXPORT_SHARE_PER_MILLE as f64 / 1000.0;
    let bytes = if total == 0 { 0.0 } else { (sent.min(total) as f64) / (total as f64) };
    let export = if export_fraction.is_finite() { export_fraction.clamp(0.0, 1.0) } else { 0.0 };
    match stage {
        VideoSendStage::Upload => bytes,
        VideoSendStage::Exporting => share * export,
        VideoSendStage::UploadAfterExport => share + (1.0 - share) * bytes,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const MB: u64 = 1024 * 1024;

    fn source(width: u32, height: u32, seconds: u64, bytes: u64) -> VideoSource {
        VideoSource { width, height, duration_ms: seconds * 1000, bytes }
    }

    #[test]
    fn a_one_minute_4k_video_is_recompressed_only_with_the_setting_on() {
        // iPhone 4K30 HEVC: about 170 MB a minute.
        let clip = source(3840, 2160, 60, 170 * MB);
        assert_eq!(video_recompress_plan(false, clip).reason, VideoRecompressReason::Off);
        assert!(!video_recompress_plan(false, clip).recompress);
        let on = video_recompress_plan(true, clip);
        assert!(on.recompress);
        assert_eq!(on.reason, VideoRecompressReason::LargerThanTarget);
        assert_eq!(on.bitrate, 170 * MB * 8 / 60);
    }

    #[test]
    fn portrait_4k_counts_its_long_side() {
        assert_eq!(
            video_recompress_plan(true, source(2160, 3840, 60, 170 * MB)).reason,
            VideoRecompressReason::LargerThanTarget
        );
    }

    #[test]
    fn a_small_or_modest_1080p_video_goes_as_it_is() {
        assert_eq!(
            video_recompress_plan(true, source(3840, 2160, 2, 5 * MB)).reason,
            VideoRecompressReason::Small
        );
        // 1080p at 8 Mbit/s: 60 MB a minute.
        assert_eq!(
            video_recompress_plan(true, source(1920, 1080, 60, 60 * MB)).reason,
            VideoRecompressReason::WithinTarget
        );
    }

    #[test]
    fn a_high_bitrate_1080p_video_is_recompressed() {
        // 1080p60 H.264 at about 30 Mbit/s.
        let plan = video_recompress_plan(true, source(1920, 1080, 60, 225 * MB));
        assert!(plan.recompress);
        assert_eq!(plan.reason, VideoRecompressReason::HighBitrate);
    }

    #[test]
    fn unreadable_facts_send_the_original() {
        assert_eq!(
            video_recompress_plan(true, source(0, 0, 60, 170 * MB)).reason,
            VideoRecompressReason::Unknown
        );
        assert_eq!(
            video_recompress_plan(true, source(3840, 2160, 0, 170 * MB)).reason,
            VideoRecompressReason::Unknown
        );
    }

    #[test]
    fn the_export_goes_only_when_clearly_smaller() {
        assert!(video_recompress_keep(170 * MB, 60 * MB));
        assert!(video_recompress_keep(100, 90));
        assert!(!video_recompress_keep(100, 91));
        assert!(!video_recompress_keep(170 * MB, 0));
        assert!(!video_recompress_keep(0, 0));
    }

    #[test]
    fn the_send_bar_runs_export_then_upload_and_only_forward() {
        let close = |a: f64, b: f64| (a - b).abs() < 1e-9;
        assert!(close(video_send_fraction(VideoSendStage::Upload, 0.0, 50, 100), 0.5));
        assert!(close(video_send_fraction(VideoSendStage::Exporting, 0.0, 0, 0), 0.0));
        assert!(close(video_send_fraction(VideoSendStage::Exporting, 0.5, 0, 0), 0.15));
        assert!(close(video_send_fraction(VideoSendStage::Exporting, 1.0, 0, 0), 0.3));
        assert!(close(video_send_fraction(VideoSendStage::UploadAfterExport, 1.0, 0, 62), 0.3));
        assert!(close(video_send_fraction(VideoSendStage::UploadAfterExport, 1.0, 31, 62), 0.65));
        assert!(close(video_send_fraction(VideoSendStage::UploadAfterExport, 1.0, 62, 62), 1.0));
        // Out-of-range inputs stay on the bar.
        assert!(close(video_send_fraction(VideoSendStage::Exporting, f64::NAN, 0, 0), 0.0));
        assert!(close(video_send_fraction(VideoSendStage::Exporting, 7.0, 0, 0), 0.3));
        assert!(close(video_send_fraction(VideoSendStage::Upload, 0.0, 200, 100), 1.0));
        assert!(close(video_send_fraction(VideoSendStage::Upload, 0.0, 5, 0), 0.0));
    }
}
