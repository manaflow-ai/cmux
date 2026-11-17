//! The screen-share viewer's Follow mode: the shared follow camera
//! (`cmux-follow-cam`) behind a uniffi object, so the phone shows a portrait
//! crop of the Mac's screen that follows the pointer, the text caret, the
//! focused window and changed pixels.
//!
//! The Mac sends one JSON event per message on the screen stream's `focus`
//! channel. Its `t_us` is the Mac's clock, so each event is stamped again
//! with the phone's clock when it arrives ([`FollowCamera::push_json`]); the
//! camera then runs on one clock, the one the viewer's display link reads
//! (`CACurrentMediaTime` in microseconds).
//!
//! One object per viewer. Events come from the link's thread and frames from
//! the main thread, so the camera sits behind a mutex held only for the call.

use std::sync::{Mutex, MutexGuard, PoisonError};

use cmux_follow_cam::{Camera, Config, Event, Mode, Rect, Signal};

use crate::CmuxMobileError;

/// A rect in the shared screen's pixels, origin top left.
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct FollowRect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

impl From<Rect> for FollowRect {
    fn from(rect: Rect) -> Self {
        Self { x: rect.x, y: rect.y, w: rect.w, h: rect.h }
    }
}

impl From<FollowRect> for Rect {
    fn from(rect: FollowRect) -> Self {
        Rect::new(rect.x, rect.y, rect.w, rect.h)
    }
}

/// Who moves the crop: the camera, or the person (a pinch or a drag).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FollowCameraMode {
    Follow,
    Manual,
}

struct Inner {
    camera: Camera,
    /// The shared screen's size, from the constructor or the last `source`
    /// event: what the crop's pixels are relative to.
    source: (f64, f64),
}

/// One viewer's follow camera.
#[derive(uniffi::Object)]
pub struct FollowCamera {
    inner: Mutex<Inner>,
}

impl FollowCamera {
    fn inner(&self) -> MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

#[uniffi::export]
impl FollowCamera {
    /// A crop of `aspect` (width over height: the viewer's own shape, about
    /// 9/16 on a portrait iPhone) over a screen of `source_w` x `source_h`
    /// pixels, as large as the screen holds, centred. `reduce_motion`
    /// (the system's Reduce Motion) cuts to each new framing instead of
    /// panning.
    #[uniffi::constructor]
    pub fn new(aspect: f64, source_w: f64, source_h: f64, reduce_motion: bool) -> Self {
        let _ = (aspect, source_w, source_h, reduce_motion);
        Self {
            inner: Mutex::new(Inner { camera: Camera::new(Config::default(), 1.0, 1.0), source: (1.0, 1.0) }),
        }
    }

    /// One message of the `focus` channel (a JSON event), received at
    /// `now_us` on the phone's clock.
    pub fn push_json(&self, line: String, now_us: u64) -> Result<(), CmuxMobileError> {
        let _ = (line, now_us);
        Ok(())
    }

    /// Moves time to `now_us` and returns the crop: once per display frame.
    pub fn advance(&self, now_us: u64) -> FollowRect {
        let _ = now_us;
        self.inner().camera.rect().into()
    }

    /// The person took the camera: hold `rect` (and its size).
    pub fn manual(&self, rect: FollowRect) {
        let _ = rect;
    }

    /// Hands the camera back: it pans from where the person left it.
    pub fn resume(&self) {}

    pub fn mode(&self) -> FollowCameraMode {
        FollowCameraMode::Follow
    }

    /// The shared screen's size (`x` and `y` are 0).
    pub fn source(&self) -> FollowRect {
        let (w, h) = self.inner().source;
        FollowRect { x: 0.0, y: 0.0, w, h }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const MS: u64 = 1_000;
    const W: f64 = 3024.0;
    const H: f64 = 1964.0;

    fn camera() -> FollowCamera {
        FollowCamera::new(9.0 / 16.0, W, H, false)
    }

    #[test]
    fn starts_as_the_largest_centred_portrait_crop() {
        let rect = camera().advance(0);
        assert!((rect.h - H).abs() < 1e-6, "{rect:?}");
        assert!((rect.w - H * 9.0 / 16.0).abs() < 1e-6, "{rect:?}");
        assert!((rect.x - (W - rect.w) / 2.0).abs() < 1e-6, "{rect:?}");
        assert_eq!(rect.y, 0.0);
    }

    /// The Mac's clock is far from the phone's: the caret still moves the
    /// crop, because events take the phone's time when they arrive.
    #[test]
    fn a_caret_on_another_clock_pans_the_crop_to_it() {
        let camera = camera();
        let mut now = 5 * MS;
        camera.advance(now);
        // A window first (a cut), then a caret at the screen's right edge.
        camera
            .push_json(
                r#"{"t_us":987654321000,"kind":"window","id":7,"x":0,"y":0,"w":3024,"h":1964}"#.into(),
                now,
            )
            .unwrap();
        now += 400 * MS;
        camera.advance(now);
        let before = camera.advance(now);
        camera
            .push_json(r#"{"t_us":987654722000,"kind":"caret","x":2900,"y":900,"w":2,"h":30}"#.into(), now)
            .unwrap();
        let mut rect = before;
        for _ in 0..120 {
            now += 16 * MS;
            rect = camera.advance(now);
        }
        assert!(rect.x > before.x + 500.0, "panned right: {before:?} -> {rect:?}");
        assert!(rect.x <= rect.x + rect.w && 2901.0 <= rect.x + rect.w, "caret in view: {rect:?}");
        assert_eq!(camera.mode(), FollowCameraMode::Follow);
    }

    /// An app switch is a cut: the crop is on the new window at once.
    #[test]
    fn a_window_switch_cuts() {
        let camera = camera();
        let now = 10 * MS;
        camera.advance(now);
        camera
            .push_json(r#"{"t_us":1,"kind":"window","id":1,"x":0,"y":0,"w":600,"h":1964}"#.into(), now)
            .unwrap();
        let rect = camera.advance(now + 16 * MS);
        assert_eq!(rect.x, 0.0, "snapped to the left window: {rect:?}");
        camera
            .push_json(
                r#"{"t_us":2,"kind":"window","id":2,"x":2400,"y":0,"w":624,"h":1964}"#.into(),
                now + 500 * MS,
            )
            .unwrap();
        let rect = camera.advance(now + 516 * MS);
        assert!((rect.x + rect.w - W).abs() < 1e-6, "snapped to the right window: {rect:?}");
    }

    #[test]
    fn manual_holds_and_resume_hands_back() {
        let camera = camera();
        let mut now = 0;
        camera.advance(now);
        camera
            .push_json(r#"{"t_us":0,"kind":"window","id":1,"x":0,"y":0,"w":600,"h":1964}"#.into(), now)
            .unwrap();
        now += 16 * MS;
        camera.advance(now);
        let held = FollowRect { x: 2000.0, y: 500.0, w: 552.0, h: 982.0 };
        camera.manual(held);
        assert_eq!(camera.mode(), FollowCameraMode::Manual);
        now += 2_000 * MS;
        assert_eq!(camera.advance(now), held, "manual holds the person's crop");
        camera.resume();
        assert_eq!(camera.mode(), FollowCameraMode::Follow);
        let mut rect = held;
        for _ in 0..200 {
            now += 16 * MS;
            rect = camera.advance(now);
        }
        assert_eq!(rect.x, 0.0, "back on the focused window: {rect:?}");
        assert_eq!((rect.w, rect.h), (held.w, held.h), "keeps the person's size");
    }

    /// A Mac without the Accessibility grant sends no window and no caret:
    /// damage and a moving pointer still steer the crop.
    #[test]
    fn follows_damage_and_the_pointer_without_window_or_caret() {
        let camera = camera();
        let mut now = 0;
        let start = camera.advance(now);
        camera.push_json(r#"{"t_us":0,"kind":"damage","x":100,"y":800,"w":200,"h":40}"#.into(), now).unwrap();
        let mut rect = start;
        for _ in 0..120 {
            now += 16 * MS;
            rect = camera.advance(now);
        }
        assert_eq!(rect.x, 0.0, "panned left to the damage: {start:?} -> {rect:?}");
        camera.push_json(r#"{"t_us":0,"kind":"pointer","x":100,"y":800}"#.into(), now).unwrap();
        camera.push_json(r#"{"t_us":0,"kind":"pointer","x":2950,"y":900}"#.into(), now).unwrap();
        for _ in 0..120 {
            now += 16 * MS;
            rect = camera.advance(now);
        }
        assert!(rect.x + rect.w >= 2950.0 && rect.x <= 2950.0, "pointer in view: {rect:?}");
    }

    #[test]
    fn a_source_event_resizes_and_reports_the_screen() {
        let camera = camera();
        camera.advance(0);
        camera.push_json(r#"{"t_us":0,"kind":"source","w":1920,"h":1080}"#.into(), MS).unwrap();
        assert_eq!(camera.source(), FollowRect { x: 0.0, y: 0.0, w: 1920.0, h: 1080.0 });
        let rect = camera.advance(2 * MS);
        assert!((rect.h - 1080.0).abs() < 1e-6, "{rect:?}");
    }

    /// Reduce Motion: a move is a cut, on the next frame.
    #[test]
    fn reduce_motion_cuts_instead_of_panning() {
        let camera = FollowCamera::new(9.0 / 16.0, W, H, true);
        let mut now = 0;
        camera.advance(now);
        camera
            .push_json(r#"{"t_us":0,"kind":"window","id":1,"x":0,"y":0,"w":3024,"h":1964}"#.into(), now)
            .unwrap();
        now += 400 * MS;
        camera.advance(now);
        camera.push_json(r#"{"t_us":0,"kind":"caret","x":2900,"y":900,"w":2,"h":30}"#.into(), now).unwrap();
        let rect = camera.advance(now + 16 * MS);
        assert!((rect.x + rect.w - W).abs() < 1e-6, "on the caret one frame later: {rect:?}");
    }

    #[test]
    fn a_bad_message_is_refused_and_changes_nothing() {
        let camera = camera();
        let before = camera.advance(0);
        assert!(matches!(camera.push_json("{".into(), MS), Err(CmuxMobileError::InvalidArgument { .. })));
        assert!(matches!(
            camera.push_json(r#"{"t_us":0,"kind":"teleport","x":1}"#.into(), MS),
            Err(CmuxMobileError::InvalidArgument { .. })
        ));
        assert_eq!(camera.advance(2 * MS), before);
        assert_eq!(camera.source(), FollowRect { x: 0.0, y: 0.0, w: W, h: H });
    }
}
