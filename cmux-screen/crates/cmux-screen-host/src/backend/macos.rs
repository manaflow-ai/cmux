//! macOS: ScreenCaptureKit captures one display at its native pixel size,
//! 60 fps, only when it changes, as NV12 straight to the hardware encoder
//! (no copy: the CVPixelBuffer goes to libwebrtc as a native buffer).
//! CGEvent posts the viewer's input as if from this Mac's own keyboard and
//! mouse. Needs Screen Recording and Accessibility for the host process
//! (or the app that launched it).

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, mpsc};
use std::thread;
use std::time::{Duration, Instant};

use cmux_screen_proto::{DisplaySize, Input};
use core_graphics::display::CGDisplay;
use core_graphics::event::{
    CGEvent, CGEventFlags, CGEventTapLocation, CGEventType, CGKeyCode, CGMouseButton, EventField, ScrollEventUnit,
};
use core_graphics::event_source::{CGEventSource, CGEventSourceStateID};
use core_graphics::geometry::CGPoint;
use libwebrtc::video_frame::native::NativeBuffer;
use libwebrtc::video_frame::{VideoFrame, VideoRotation};
use libwebrtc::video_source::native::NativeVideoSource;
use screencapturekit::CVPixelBuffer;
use screencapturekit::cm::SCFrameStatus;
use screencapturekit::prelude::*;
use unicode_segmentation::UnicodeSegmentation;

use super::{Backend, DisplaysCallback};
use crate::log;

/// A still screen sends nothing; a lost keyframe or a quality step needs a
/// frame to encode, so the last one is repeated this often.
const IDLE_REFRESH: Duration = Duration::from_millis(500);

#[derive(Clone, Copy, Default)]
struct Rect {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
}

struct State {
    displays: Vec<SCDisplay>,
    current: usize,
    stream: Option<SCStream>,
    video: Option<NativeVideoSource>,
    on_displays: Option<DisplaysCallback>,
    last: Option<(CVPixelBuffer, Instant)>,
    /// Complete frames ScreenCaptureKit delivered, and frames it marked idle/blank/dropped.
    complete: u64,
    other: u64,
}

pub struct MacBackend {
    state: Arc<Mutex<State>>,
    running: Arc<AtomicBool>,
    /// The streamed display in global points, for input coordinates.
    bounds: Arc<Mutex<Rect>>,
    input: Mutex<Option<mpsc::Sender<Input>>>,
}

// SCDisplay and SCStream are thread-safe Objective-C objects behind the crate's wrappers.
unsafe impl Send for State {}

impl MacBackend {
    pub fn new() -> Self {
        Self {
            state: Arc::new(Mutex::new(State {
                displays: vec![],
                current: 0,
                stream: None,
                video: None,
                on_displays: None,
                last: None,
                complete: 0,
                other: 0,
            })),
            running: Arc::new(AtomicBool::new(false)),
            bounds: Arc::new(Mutex::new(Rect::default())),
            input: Mutex::new(None),
        }
    }
}

impl Default for MacBackend {
    fn default() -> Self {
        Self::new()
    }
}

/// The display's size in pixels (Retina displays capture at full density),
/// fitted to what H.264 can carry.
fn pixel_size(display: &SCDisplay) -> DisplaySize {
    let mode = CGDisplay::new(display.display_id()).display_mode();
    let native = match mode {
        Some(mode) => DisplaySize { w: mode.pixel_width() as u32, h: mode.pixel_height() as u32 },
        None => DisplaySize { w: display.width(), h: display.height() },
    };
    fit_for_encoder(native)
}

/// The largest picture the viewer's H.264 level (5.2) takes: 3840x2160
/// keeps a 16:9 4K display whole; a 5K or 6K display is scaled down by
/// ScreenCaptureKit (on the GPU) to fit, keeping its aspect ratio. Sizes are
/// even, as the 4:2:0 encoder needs.
fn fit_for_encoder(size: DisplaySize) -> DisplaySize {
    const MAX: (f64, f64) = (3840.0, 2160.0);
    let scale = (MAX.0 / f64::from(size.w)).min(MAX.1 / f64::from(size.h)).min(1.0);
    let even = |value: f64| (value.round() as u32) & !1;
    DisplaySize { w: even(f64::from(size.w) * scale), h: even(f64::from(size.h) * scale) }
}

#[link(name = "CoreVideo", kind = "framework")]
unsafe extern "C" {
    fn CVPixelBufferRetain(buffer: *mut std::ffi::c_void) -> *mut std::ffi::c_void;
}

fn push(video: &NativeVideoSource, buffer: &CVPixelBuffer) {
    // SAFETY: `buffer` is a live CVPixelBuffer. libwebrtc's wrapper takes
    // ownership of one reference (it releases the buffer after wrapping it),
    // so it gets a reference of its own, not the one `buffer` holds.
    let native = unsafe { NativeBuffer::from_cv_pixel_buffer(CVPixelBufferRetain(buffer.as_ptr())) };
    video.capture_frame(&VideoFrame {
        rotation: VideoRotation::VideoRotation0,
        timestamp_us: crate::clock_us(),
        frame_metadata: None,
        buffer: native,
    });
}

fn capture(state: &Arc<Mutex<State>>, bounds: &Arc<Mutex<Rect>>, index: usize) -> anyhow::Result<()> {
    let display = state.lock().unwrap().displays.get(index).cloned().ok_or_else(|| anyhow::anyhow!("no display {index}"))?;
    let size = pixel_size(&display);
    let filter = SCContentFilter::create().with_display(&display).with_excluding_windows(&[]).build()?;
    let configuration = SCStreamConfiguration::new()
        .with_width(size.w)
        .with_height(size.h)
        .with_fps(60)
        .with_pixel_format(PixelFormat::YCbCr_420v)
        .with_queue_depth(4)
        .with_shows_cursor(true)
        .with_color_space_name("kCGColorSpaceSRGB")?;
    let mut stream = SCStream::new(&filter, &configuration)?;
    let sink = state.clone();
    stream.add_output_handler(
        move |sample: CMSampleBuffer, kind: SCStreamOutputType| {
            if kind != SCStreamOutputType::Screen {
                return;
            }
            if sample.frame_status() != Some(SCFrameStatus::Complete) {
                sink.lock().unwrap().other += 1;
                return;
            }
            let Some(buffer) = sample.pixel_buffer() else { return };
            let video = {
                let mut state = sink.lock().unwrap();
                // After stop() a late frame must not be kept.
                if state.video.is_some() {
                    state.last = Some((buffer.clone(), Instant::now()));
                    state.complete += 1;
                }
                state.video.clone()
            };
            if let Some(video) = video {
                push(&video, &buffer);
            }
        },
        SCStreamOutputType::Screen,
    )?;
    stream.start_capture()?;
    let frame = display.frame();
    *bounds.lock().unwrap() = Rect { x: frame.origin.x, y: frame.origin.y, w: frame.size.width, h: frame.size.height };
    let previous = {
        let mut state = state.lock().unwrap();
        state.current = index;
        state.stream.replace(stream)
    };
    if let Some(previous) = previous {
        let _ = previous.stop_capture();
    }
    log(format!("capturing display {} at {}x{}, 60 fps", display.display_id(), size.w, size.h));
    Ok(())
}

impl Backend for MacBackend {
    fn start(&self, video: NativeVideoSource, displays: DisplaysCallback) -> anyhow::Result<()> {
        let content = SCShareableContent::get()?;
        let mut found = content.displays();
        found.sort_by(|a, b| a.frame().origin.x.total_cmp(&b.frame().origin.x));
        let main = CGDisplay::main().id;
        let index = found.iter().position(|d| d.display_id() == main).unwrap_or(0);
        let sizes: Vec<DisplaySize> = found.iter().map(pixel_size).collect();
        {
            let mut state = self.state.lock().unwrap();
            state.displays = found;
            state.video = Some(video.clone());
            state.on_displays = Some(displays.clone());
        }
        displays(sizes, index);
        self.running.store(true, Ordering::SeqCst);
        capture(&self.state, &self.bounds, index)?;

        let (state, running) = (self.state.clone(), self.running.clone());
        thread::Builder::new().name("cmux-screen-refresh".into()).spawn(move || {
            let mut ticks = 0u32;
            while running.load(Ordering::SeqCst) {
                thread::sleep(IDLE_REFRESH); // idle refresh period
                ticks += 1;
                if ticks.is_multiple_of(6) {
                    let (complete, other) = {
                        let mut state = state.lock().unwrap();
                        (std::mem::take(&mut state.complete), std::mem::take(&mut state.other))
                    };
                    log(format!("capture: {complete} complete frames, {other} idle in 3 s"));
                }
                let stale = {
                    let state = state.lock().unwrap();
                    match (&state.last, &state.video) {
                        (Some((buffer, at)), Some(video)) if at.elapsed() >= IDLE_REFRESH => Some((buffer.clone(), video.clone())),
                        _ => None,
                    }
                };
                if let Some((buffer, video)) = stale {
                    push(&video, &buffer);
                }
            }
        })?;

        let (sender, receiver) = mpsc::channel::<Input>();
        let bounds = self.bounds.clone();
        thread::Builder::new().name("cmux-screen-input".into()).spawn(move || {
            let mut injector = Injector::new(bounds);
            for input in receiver {
                injector.handle(input);
            }
        })?;
        *self.input.lock().unwrap() = Some(sender);
        Ok(())
    }

    fn select(&self, index: usize) {
        let (sizes, callback) = {
            let state = self.state.lock().unwrap();
            if index >= state.displays.len() || index == state.current {
                return;
            }
            (state.displays.iter().map(pixel_size).collect::<Vec<_>>(), state.on_displays.clone())
        };
        if let Err(error) = capture(&self.state, &self.bounds, index) {
            log(format!("display {index}: {error}"));
            return;
        }
        if let Some(callback) = callback {
            callback(sizes, index);
        }
    }

    fn handle(&self, input: Input) {
        if let Some(sender) = self.input.lock().unwrap().as_ref() {
            let _ = sender.send(input);
        }
    }

    fn stop(&self) {
        self.running.store(false, Ordering::SeqCst);
        self.input.lock().unwrap().take();
        let stream = {
            let mut state = self.state.lock().unwrap();
            state.video = None;
            state.last = None;
            state.stream.take()
        };
        if let Some(stream) = stream {
            let _ = stream.stop_capture();
        }
    }
}

/// Posts input with CGEvent at the HID level: absolute pointer positions on
/// the streamed display, button transitions with click counting, wheel
/// scrolling, keys by virtual key code, and text as Unicode strings.
struct Injector {
    bounds: Arc<Mutex<Rect>>,
    source: Option<CGEventSource>,
    buttons: u8,
    point: CGPoint,
    last_click: (Instant, u8, i64),
    flags: CGEventFlags,
}

/// macOS's default double-click interval.
const DOUBLE_CLICK: Duration = Duration::from_millis(500);

impl Injector {
    fn new(bounds: Arc<Mutex<Rect>>) -> Self {
        Self {
            bounds,
            source: CGEventSource::new(CGEventSourceStateID::HIDSystemState).ok(),
            buttons: 0,
            point: CGPoint::new(0.0, 0.0),
            last_click: (Instant::now(), 0, 0),
            flags: CGEventFlags::empty(),
        }
    }

    fn handle(&mut self, input: Input) {
        match input {
            Input::Pointer { x, y, buttons } => {
                self.point = self.location(x, y);
                self.set_buttons(buttons);
            }
            Input::Scroll { x, y, dx, dy } => {
                self.point = self.location(x, y);
                self.mouse(CGEventType::MouseMoved, CGMouseButton::Left, None);
                if let Some(source) = self.source.clone()
                    && let Ok(event) = CGEvent::new_scroll_event(source, ScrollEventUnit::LINE, 2, dy, dx, 0) {
                        event.post(CGEventTapLocation::HID);
                    }
            }
            Input::Key { keysym, down } => self.key(keysym, down),
            Input::Chord { modifiers, keysym } => {
                for &modifier in &modifiers {
                    self.key(modifier, true);
                }
                self.key(keysym, true);
                self.key(keysym, false);
                for &modifier in modifiers.iter().rev() {
                    self.key(modifier, false);
                }
            }
            Input::Text(text) => {
                // One visible character at a time (emoji sequences and
                // combining accents stay whole), as the Swift host types.
                for grapheme in text.graphemes(true) {
                    self.type_text(grapheme);
                }
            }
            Input::SelectDisplay(_) | Input::Quality(_) | Input::Refresh => {}
        }
    }

    fn location(&self, x: f64, y: f64) -> CGPoint {
        let bounds = *self.bounds.lock().unwrap();
        CGPoint::new(bounds.x + x * bounds.w, bounds.y + y * bounds.h)
    }

    fn mouse(&self, kind: CGEventType, button: CGMouseButton, click_state: Option<i64>) {
        let Some(source) = self.source.clone() else { return };
        if let Ok(event) = CGEvent::new_mouse_event(source, kind, self.point, button) {
            if let Some(count) = click_state {
                event.set_integer_value_field(EventField::MOUSE_EVENT_CLICK_STATE, count);
            }
            event.post(CGEventTapLocation::HID);
        }
    }

    /// Moves, then posts a down or up for each button whose state changed.
    fn set_buttons(&mut self, next: u8) {
        let changed = next ^ self.buttons;
        let held = self.buttons;
        self.buttons = next;
        if changed == 0 {
            let kind = if held & 1 != 0 {
                CGEventType::LeftMouseDragged
            } else if held & 4 != 0 {
                CGEventType::RightMouseDragged
            } else {
                CGEventType::MouseMoved
            };
            self.mouse(kind, CGMouseButton::Left, None);
            return;
        }
        let buttons = [
            (1u8, CGMouseButton::Left, CGEventType::LeftMouseDown, CGEventType::LeftMouseUp),
            (4, CGMouseButton::Right, CGEventType::RightMouseDown, CGEventType::RightMouseUp),
            (2, CGMouseButton::Center, CGEventType::OtherMouseDown, CGEventType::OtherMouseUp),
        ];
        for (bit, button, down, up) in buttons {
            if changed & bit == 0 {
                continue;
            }
            let pressing = next & bit != 0;
            if pressing {
                // Double and triple clicks: macOS counts them from the click state.
                let (at, last_bit, count) = self.last_click;
                let count = if at.elapsed() < DOUBLE_CLICK && last_bit == bit { count + 1 } else { 1 };
                self.last_click = (Instant::now(), bit, count);
            }
            self.mouse(if pressing { down } else { up }, button, Some(self.last_click.2));
        }
    }

    fn key(&mut self, keysym: u32, down: bool) {
        if let Some(flag) = modifier_flag(keysym) {
            if down {
                self.flags.insert(flag);
            } else {
                self.flags.remove(flag);
            }
        }
        let Some((code, shifted)) = key_code(keysym) else {
            if down
                && let Some(character) = keysym_char(keysym) {
                    self.type_text(character.encode_utf8(&mut [0; 4]));
                }
            return;
        };
        let Some(source) = self.source.clone() else { return };
        if let Ok(event) = CGEvent::new_keyboard_event(source, code, down) {
            event.set_flags(if shifted { self.flags | CGEventFlags::CGEventFlagShift } else { self.flags });
            event.post(CGEventTapLocation::HID);
        }
    }

    fn type_text(&self, text: &str) {
        let Some(source) = self.source.clone() else { return };
        let units: Vec<u16> = text.encode_utf16().collect();
        for down in [true, false] {
            if let Ok(event) = CGEvent::new_keyboard_event(source.clone(), 0, down) {
                event.set_string_from_utf16_unchecked(&units);
                event.set_flags(self.flags);
                event.post(CGEventTapLocation::HID);
            }
        }
    }
}

fn modifier_flag(keysym: u32) -> Option<CGEventFlags> {
    Some(match keysym {
        0xFFE1 | 0xFFE2 => CGEventFlags::CGEventFlagShift,
        0xFFE3 | 0xFFE4 => CGEventFlags::CGEventFlagControl,
        0xFFE9 | 0xFFEA => CGEventFlags::CGEventFlagAlternate,
        0xFFEB | 0xFFEC | 0xFFE7 | 0xFFE8 => CGEventFlags::CGEventFlagCommand,
        _ => return None,
    })
}

fn keysym_char(keysym: u32) -> Option<char> {
    if keysym <= 0xFF {
        char::from_u32(keysym)
    } else if keysym & 0xFF00_0000 == 0x0100_0000 {
        char::from_u32(keysym & 0x00FF_FFFF)
    } else {
        None
    }
}

/// macOS virtual key codes (ANSI layout) by keysym; `true` for the upper
/// symbol of a key (sent with Shift).
fn key_code(keysym: u32) -> Option<(CGKeyCode, bool)> {
    let special = match keysym {
        0xFF0D => 36, 0xFF8D => 76, 0xFF09 => 48, 0x20 => 49, 0xFF08 => 51, 0xFF1B => 53, 0xFFFF => 117,
        0xFF51 => 123, 0xFF53 => 124, 0xFF54 => 125, 0xFF52 => 126, 0xFF50 => 115, 0xFF57 => 119, 0xFF55 => 116,
        0xFF56 => 121, 0xFFE1 => 56, 0xFFE2 => 60, 0xFFE3 => 59, 0xFFE4 => 62, 0xFFE9 => 58, 0xFFEA => 61,
        0xFFEB | 0xFFE7 => 55, 0xFFEC | 0xFFE8 => 54, 0xFFE5 => 57,
        0xFFBE => 122, 0xFFBF => 120, 0xFFC0 => 99, 0xFFC1 => 118, 0xFFC2 => 96, 0xFFC3 => 97, 0xFFC4 => 98,
        0xFFC5 => 100, 0xFFC6 => 101, 0xFFC7 => 109, 0xFFC8 => 103, 0xFFC9 => 111,
        _ => u16::MAX,
    };
    if special != u16::MAX {
        return Some((special, false));
    }
    let character = char::from_u32(keysym).filter(|_| keysym <= 0x7E)?;
    if let Some(code) = plain(character) {
        return Some((code, false));
    }
    if character.is_ascii_uppercase() {
        return plain(character.to_ascii_lowercase()).map(|code| (code, true));
    }
    let base = match character {
        '!' => '1', '@' => '2', '#' => '3', '$' => '4', '%' => '5', '^' => '6', '&' => '7', '*' => '8', '(' => '9',
        ')' => '0', '_' => '-', '+' => '=', '{' => '[', '}' => ']', '|' => '\\', ':' => ';', '"' => '\'', '<' => ',',
        '>' => '.', '?' => '/', '~' => '`',
        _ => return None,
    };
    plain(base).map(|code| (code, true))
}

fn plain(character: char) -> Option<CGKeyCode> {
    Some(match character {
        'a' => 0, 's' => 1, 'd' => 2, 'f' => 3, 'h' => 4, 'g' => 5, 'z' => 6, 'x' => 7, 'c' => 8, 'v' => 9,
        'b' => 11, 'q' => 12, 'w' => 13, 'e' => 14, 'r' => 15, 'y' => 16, 't' => 17, '1' => 18, '2' => 19,
        '3' => 20, '4' => 21, '6' => 22, '5' => 23, '=' => 24, '9' => 25, '7' => 26, '-' => 27, '8' => 28,
        '0' => 29, ']' => 30, 'o' => 31, 'u' => 32, '[' => 33, 'i' => 34, 'p' => 35, 'l' => 37, 'j' => 38,
        '\'' => 39, 'k' => 40, ';' => 41, '\\' => 42, ',' => 43, '/' => 44, 'n' => 45, 'm' => 46, '.' => 47,
        '`' => 50,
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn large_displays_are_fitted_to_h264_and_small_ones_kept() {
        let fit = |w, h| fit_for_encoder(DisplaySize { w, h });
        assert_eq!(fit(1920, 1080), DisplaySize { w: 1920, h: 1080 });
        assert_eq!(fit(3840, 2160), DisplaySize { w: 3840, h: 2160 });
        assert_eq!(fit(5120, 2880), DisplaySize { w: 3840, h: 2160 }, "Studio Display 5K");
        assert_eq!(fit(6016, 3384), DisplaySize { w: 3840, h: 2160 }, "Pro Display XDR 6K");
        assert_eq!(fit(3456, 2234), DisplaySize { w: 3342, h: 2160 }, "MacBook Pro 16 keeps its aspect");
        assert_eq!(fit(2560, 1664), DisplaySize { w: 2560, h: 1664 }, "MacBook Air 13");
        assert_eq!(fit(1001, 667), DisplaySize { w: 1000, h: 666 }, "odd sizes are made even");
    }

    #[test]
    fn keysyms_map_to_the_same_key_codes_as_the_swift_host() {
        assert_eq!(key_code(0xFF0D), Some((36, false)), "Return");
        assert_eq!(key_code('a' as u32), Some((0, false)));
        assert_eq!(key_code('A' as u32), Some((0, true)));
        assert_eq!(key_code('?' as u32), Some((44, true)));
        assert_eq!(key_code(0xFFE7), Some((55, false)), "Meta_L is Command");
        assert_eq!(key_code(0x00E9), None, "é is typed as text");
        assert_eq!(keysym_char(0x00E9), Some('é'));
        assert_eq!(keysym_char(0x0100_20AC), Some('€'));
    }
}
