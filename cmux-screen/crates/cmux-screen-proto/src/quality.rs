use std::str::FromStr;

/// The viewer's choice of stream quality. `Auto` leaves the trade-offs to
/// WebRTC (sharp text first); the fixed presets hold a resolution, frame
/// rate and bitrate even when the network cannot carry them, which shows
/// as lag and stalls instead of blur.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Quality {
    #[default]
    Auto,
    Smooth,
    Low,
    Medium,
    High,
}

/// What WebRTC gives up first when the network is tight.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Degradation {
    /// Keep resolution, drop frames (sharp text).
    MaintainResolution,
    /// Keep frame rate, drop resolution (smooth motion).
    MaintainFramerate,
    /// Keep both; only image quality varies.
    Disabled,
}

/// A sender's encoding for one quality on one display.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct QualitySettings {
    pub degradation: Degradation,
    pub max_bitrate: u64,
    /// The bitrate a fixed preset asks the congestion controller to hold.
    pub min_bitrate: Option<u64>,
    pub max_framerate: f64,
    pub scale_down: f64,
}

impl Quality {
    pub const ALL: [Quality; 5] = [Quality::Auto, Quality::Smooth, Quality::Low, Quality::Medium, Quality::High];

    pub fn name(self) -> &'static str {
        match self {
            Self::Auto => "auto",
            Self::Smooth => "smooth",
            Self::Low => "low",
            Self::Medium => "medium",
            Self::High => "high",
        }
    }

    /// The encoding for a display `source_height` pixels tall (0: unknown).
    /// Same numbers as the Swift host (`ScreenQuality.settings`).
    pub fn settings(self, source_height: u32) -> QualitySettings {
        let scale = |height: u32| if source_height > height { f64::from(source_height) / f64::from(height) } else { 1.0 };
        let fixed = |bitrate: u64, fps: f64, scale_down: f64| QualitySettings {
            degradation: Degradation::Disabled,
            max_bitrate: bitrate,
            min_bitrate: Some(bitrate),
            max_framerate: fps,
            scale_down,
        };
        match self {
            Self::Auto => QualitySettings {
                degradation: Degradation::MaintainResolution,
                max_bitrate: 12_000_000,
                min_bitrate: None,
                max_framerate: 60.0,
                scale_down: 1.0,
            },
            Self::Smooth => QualitySettings {
                degradation: Degradation::MaintainFramerate,
                max_bitrate: 12_000_000,
                min_bitrate: None,
                max_framerate: 60.0,
                scale_down: 1.0,
            },
            Self::Low => fixed(1_500_000, 30.0, scale(720)),
            Self::Medium => fixed(4_000_000, 30.0, scale(1080)),
            Self::High => fixed(10_000_000, 60.0, 1.0),
        }
    }
}

impl FromStr for Quality {
    type Err = ();

    fn from_str(name: &str) -> Result<Self, ()> {
        Self::ALL.into_iter().find(|quality| quality.name() == name).ok_or(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_match_the_swift_raw_values() {
        let names: Vec<_> = Quality::ALL.iter().map(|q| q.name()).collect();
        assert_eq!(names, ["auto", "smooth", "low", "medium", "high"]);
        assert_eq!("medium".parse(), Ok(Quality::Medium));
    }

    #[test]
    fn fixed_presets_scale_tall_displays_down_and_never_up() {
        assert_eq!(Quality::Low.settings(1080).scale_down, 1.5);
        assert_eq!(Quality::Low.settings(2160).scale_down, 3.0);
        assert_eq!(Quality::Low.settings(600).scale_down, 1.0);
        assert_eq!(Quality::Medium.settings(2160).scale_down, 2.0);
        assert_eq!(Quality::High.settings(2160).scale_down, 1.0);
        assert_eq!(Quality::Low.settings(0).scale_down, 1.0, "an unknown size is not scaled");
    }

    #[test]
    fn auto_lets_webrtc_adapt_and_fixed_presets_hold_their_rate() {
        let auto = Quality::Auto.settings(1080);
        assert_eq!(auto.degradation, Degradation::MaintainResolution);
        assert_eq!(auto.min_bitrate, None);
        let high = Quality::High.settings(1080);
        assert_eq!(high.degradation, Degradation::Disabled);
        assert_eq!(high.min_bitrate, Some(high.max_bitrate));
    }
}
