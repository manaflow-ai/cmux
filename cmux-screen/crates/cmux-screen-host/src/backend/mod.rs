//! Platform capture and input. A backend captures one display into the
//! session's video source and injects the viewer's input; everything else
//! (signaling, sessions, quality, reconnects) is shared.

use std::sync::Arc;

use cmux_screen_proto::{DisplaySize, Input};
use libwebrtc::video_source::native::NativeVideoSource;

pub mod desktop;
#[cfg(target_os = "macos")]
pub mod macos;

/// Called with every display's pixel size and the one being streamed,
/// at start and after each display change.
pub type DisplaysCallback = Arc<dyn Fn(Vec<DisplaySize>, usize) + Send + Sync>;

pub trait Backend: Send + Sync {
    /// Starts capturing the main display into `video`.
    fn start(&self, video: NativeVideoSource, displays: DisplaysCallback) -> anyhow::Result<()>;
    /// Streams display `index` instead.
    fn select(&self, index: usize);
    /// Injects the viewer's input, in arrival order.
    fn handle(&self, input: Input);
    fn stop(&self);
}

/// Which capture path a host uses.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BackendKind {
    /// The platform's native path: ScreenCaptureKit + CGEvent on macOS;
    /// elsewhere the same as `Desktop` for now.
    Native,
    /// libwebrtc's own desktop capturer (every platform; CPU frames).
    Desktop,
}

pub fn make(kind: BackendKind) -> Box<dyn Backend> {
    match kind {
        #[cfg(target_os = "macos")]
        BackendKind::Native => Box::new(macos::MacBackend::new()),
        _ => Box::new(desktop::DesktopBackend::new()),
    }
}
