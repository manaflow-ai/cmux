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
    /// The last event's Mac time and the phone time it was given: the next
    /// event at the same Mac time takes the same phone time, so the rects of
    /// one redraw stay one instant to the engine.
    last_stamp: Option<(u64, u64)>,
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
    /// A crop of `aspect` (width over height) over a screen of `source_w` x
    /// `source_h` pixels: the largest rect of `aspect` the screen holds,
    /// divided by `zoom` (at least 1), centred. The viewer picks both: a
    /// portrait crop as wide as reads well (its height then the full screen,
    /// shown letterboxed) or, zoomed further, its own shape. `reduce_motion`
    /// (the system's Reduce Motion) cuts to each new framing instead of
    /// panning.
    #[uniffi::constructor]
    pub fn new(aspect: f64, zoom: f64, source_w: f64, source_h: f64, reduce_motion: bool) -> Self {
        let mut config = Config::default();
        if aspect.is_finite() && aspect > 0.0 {
            config.aspect = aspect;
        }
        if zoom.is_finite() && zoom >= 1.0 {
            config.zoom = zoom;
        }
        if reduce_motion {
            // Fast enough that the crop reaches any goal in one motion step: a cut.
            config.max_speed = 1e6;
            config.max_accel = 1e9;
        }
        let source = (source_w.max(1.0), source_h.max(1.0));
        Self {
            inner: Mutex::new(Inner {
                camera: Camera::new(config, source.0, source.1),
                source,
                last_stamp: None,
            }),
        }
    }

    /// One message of the `focus` channel (a JSON event), received at
    /// `now_us` on the phone's clock. Its own `t_us` (the Mac's clock) is
    /// replaced by `now_us`, except that events sharing one Mac `t_us` (the
    /// rects of one redraw) all take the phone time the first of them got.
    /// A message that is not an event is refused and changes nothing.
    pub fn push_json(&self, line: String, now_us: u64) -> Result<(), CmuxMobileError> {
        let event: Event = serde_json::from_str(&line)
            .map_err(|error| CmuxMobileError::InvalidArgument { message: format!("focus event: {error}") })?;
        let mut inner = self.inner();
        if let Signal::Source { w, h } = event.signal {
            if !(w > 0.0 && h > 0.0) {
                return Err(CmuxMobileError::InvalidArgument { message: format!("focus source {w}x{h}") });
            }
            inner.source = (w, h);
        }
        let t_us = match inner.last_stamp {
            Some((mac, phone)) if mac == event.t_us => phone,
            _ => now_us,
        };
        inner.last_stamp = Some((event.t_us, t_us));
        inner.camera.push(Event { t_us, signal: event.signal });
        Ok(())
    }

    /// Moves time to `now_us` and returns the crop: once per display frame.
    pub fn advance(&self, now_us: u64) -> FollowRect {
        self.inner().camera.advance(now_us).into()
    }

    /// The person took the camera: hold `rect` (and its size).
    pub fn manual(&self, rect: FollowRect) {
        self.inner().camera.manual(rect.into());
    }

    /// Hands the camera back: it pans from where the person left it.
    pub fn resume(&self) {
        self.inner().camera.resume();
    }

    pub fn mode(&self) -> FollowCameraMode {
        match self.inner().camera.mode() {
            Mode::Follow => FollowCameraMode::Follow,
            Mode::Manual => FollowCameraMode::Manual,
        }
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
        FollowCamera::new(9.0 / 16.0, 1.0, W, H, false)
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
        // Centred on the focused window (x 0..600, the full height).
        assert_eq!(
            (rect.x + rect.w / 2.0, rect.y + rect.h / 2.0),
            (300.0, 982.0),
            "back on the window: {rect:?}"
        );
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

    /// One redraw on the Mac is many damage rects with one `t_us`, reaching
    /// the phone a little apart. They stay one instant, so a full redraw sent
    /// as strips (each under the full-redraw share) is still a full redraw
    /// and does not take the focus from the real damage (the engine's own
    /// `a_full_redraw_sent_as_many_small_rects_does_not_move_the_camera`).
    #[test]
    fn one_mac_instant_stays_one_instant_on_the_phone() {
        let camera = camera();
        camera
            .push_json(r#"{"t_us":0,"kind":"window","id":1,"x":0,"y":0,"w":3024,"h":1964}"#.into(), 0)
            .unwrap();
        camera
            .push_json(r#"{"t_us":100000,"kind":"damage","x":2800,"y":900,"w":100,"h":40}"#.into(), 100 * MS)
            .unwrap();
        let before = camera.advance(400 * MS);
        let strip = H / 16.0;
        for i in 0..16u64 {
            let y = i as f64 * strip;
            camera
                .push_json(
                    format!(r#"{{"t_us":500000,"kind":"damage","x":0,"y":{y},"w":{W},"h":{strip}}}"#),
                    500 * MS + i * MS,
                )
                .unwrap();
        }
        // Before the first damage expires (800 ms), so only the redraw can move it.
        let after = camera.advance(850 * MS);
        assert_eq!(after, before, "the split full redraw moved the camera");
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

    /// A portrait viewer's readable crop of a 1920x1080 screen: half its
    /// width at full height (shown letterboxed), not the narrow 9:16 one.
    /// Typing along a long line pans it sideways only.
    #[test]
    fn a_wide_full_height_crop_follows_a_long_line() {
        let camera = FollowCamera::new(960.0 / 1080.0, 1.0, 1920.0, 1080.0, false);
        let mut now = 0;
        let start = camera.advance(now);
        assert_eq!((start.w, start.h), (960.0, 1080.0), "{start:?}");
        camera
            .push_json(r#"{"t_us":0,"kind":"window","id":1,"x":0,"y":0,"w":1920,"h":1080}"#.into(), now)
            .unwrap();
        for column in 0..170 {
            now += 60 * MS;
            let x = 10.0 + f64::from(column) * 11.0;
            camera
                .push_json(format!(r#"{{"t_us":0,"kind":"caret","x":{x},"y":700,"w":2,"h":20}}"#), now)
                .unwrap();
            let rect = camera.advance(now);
            assert_eq!((rect.y, rect.h), (0.0, 1080.0), "full height: {rect:?}");
        }
        for _ in 0..60 {
            now += 16 * MS;
            camera.advance(now);
        }
        let rect = camera.advance(now);
        let caret = 10.0 + 169.0 * 11.0;
        assert!(rect.x <= caret && caret <= rect.x + rect.w, "the caret at the line's end: {rect:?}");
    }

    /// Reduce Motion: a move is a cut, on the next frame.
    #[test]
    fn reduce_motion_cuts_instead_of_panning() {
        let camera = FollowCamera::new(9.0 / 16.0, 1.0, W, H, true);
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
