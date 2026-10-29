//! Capture through libwebrtc's own desktop capturer, available on macOS,
//! Windows and Linux (X11 and PipeWire). Frames arrive as BGRA in memory and
//! are converted to I420 for the encoder. Input injection on platforms
//! without a native backend is not implemented yet.

use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use cmux_screen_proto::{DisplaySize, Input};
use libwebrtc::desktop_capturer::{
    CaptureSource, DesktopCaptureSourceType, DesktopCapturer, DesktopCapturerOptions, DesktopFrame,
};
use libwebrtc::native::yuv_helper;
use libwebrtc::video_frame::{I420Buffer, VideoFrame, VideoRotation};
use libwebrtc::video_source::native::NativeVideoSource;

use super::{Backend, DisplaysCallback};
use crate::log;

/// Pull rate for the capturer (it captures on request).
const FRAME_INTERVAL: Duration = Duration::from_micros(16_667);

pub struct DesktopBackend {
    running: Arc<AtomicBool>,
    selected: Arc<AtomicUsize>,
    restart: Arc<AtomicBool>,
    warned_input: AtomicBool,
    thread: Mutex<Option<thread::JoinHandle<()>>>,
}

impl DesktopBackend {
    pub fn new() -> Self {
        Self {
            running: Arc::new(AtomicBool::new(false)),
            selected: Arc::new(AtomicUsize::new(0)),
            restart: Arc::new(AtomicBool::new(false)),
            warned_input: AtomicBool::new(false),
            thread: Mutex::new(None),
        }
    }
}

impl Default for DesktopBackend {
    fn default() -> Self {
        Self::new()
    }
}

fn capturer() -> Option<DesktopCapturer> {
    let mut options = DesktopCapturerOptions::new(DesktopCaptureSourceType::Screen);
    options.set_include_cursor(true);
    #[cfg(target_os = "macos")]
    options.set_sck_system_picker(false);
    DesktopCapturer::new(options)
}

/// BGRA (libyuv "ARGB" byte order on little-endian) → I420 for the encoder.
fn to_i420(frame: &DesktopFrame) -> I420Buffer {
    let (width, height) = (frame.width() as u32 & !1, frame.height() as u32 & !1);
    let mut buffer = I420Buffer::new(width, height);
    let (stride_y, stride_u, stride_v) = buffer.strides();
    let (y, u, v) = buffer.data_mut();
    yuv_helper::argb_to_i420(
        frame.data(),
        frame.stride(),
        y,
        stride_y,
        u,
        stride_u,
        v,
        stride_v,
        width as i32,
        height as i32,
    );
    buffer
}

impl Backend for DesktopBackend {
    fn start(&self, video: NativeVideoSource, displays: DisplaysCallback) -> anyhow::Result<()> {
        let Some(probe) = capturer() else { anyhow::bail!("this platform has no desktop capturer") };
        let sources: Vec<CaptureSource> = probe.get_source_list();
        drop(probe);
        log(format!("desktop capturer: {} screen source(s)", sources.len()));
        self.running.store(true, Ordering::SeqCst);
        let (running, selected, restart) = (self.running.clone(), self.selected.clone(), self.restart.clone());
        let handle = thread::Builder::new().name("cmux-screen-capture".into()).spawn(move || {
            let sizes = Arc::new(Mutex::new(vec![DisplaySize { w: 0, h: 0 }; sources.len().max(1)]));
            while running.load(Ordering::SeqCst) {
                let Some(mut capturer) = capturer() else { return };
                let index = selected.load(Ordering::SeqCst).min(sources.len().saturating_sub(1));
                let source = sources.get(index).cloned();
                let (video, sizes_in_frame, displays_now) = (video.clone(), sizes.clone(), displays.clone());
                let mut reported = false;
                capturer.start_capture(source, move |result| {
                    let Ok(frame) = result else { return };
                    let buffer = to_i420(&frame);
                    if !reported {
                        reported = true;
                        let mut sizes = sizes_in_frame.lock().unwrap();
                        if let Some(size) = sizes.get_mut(index) {
                            *size = DisplaySize { w: frame.width() as u32, h: frame.height() as u32 };
                        }
                        displays_now(sizes.clone(), index);
                    }
                    video.capture_frame(&VideoFrame {
                        rotation: VideoRotation::VideoRotation0,
                        timestamp_us: crate::clock_us(),
                        frame_metadata: None,
                        buffer,
                    });
                });
                while running.load(Ordering::SeqCst) && !restart.swap(false, Ordering::SeqCst) {
                    let started = Instant::now();
                    capturer.capture_frame();
                    thread::sleep(FRAME_INTERVAL.saturating_sub(started.elapsed())); // capture pacing (the capturer is pull-based)
                }
            }
        })?;
        *self.thread.lock().unwrap() = Some(handle);
        Ok(())
    }

    fn select(&self, index: usize) {
        self.selected.store(index, Ordering::SeqCst);
        self.restart.store(true, Ordering::SeqCst);
    }

    fn handle(&self, _input: Input) {
        if !self.warned_input.swap(true, Ordering::SeqCst) {
            log("input is not implemented for this backend yet; the stream is view-only");
        }
    }

    fn stop(&self) {
        self.running.store(false, Ordering::SeqCst);
        if let Some(handle) = self.thread.lock().unwrap().take() {
            let _ = handle.join();
        }
    }
}
