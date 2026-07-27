#![allow(clippy::missing_safety_doc)]

mod config;
mod display;

#[allow(
    clippy::all,
    dead_code,
    improper_ctypes,
    unsafe_op_in_unsafe_fn,
    unused_imports
)]
#[path = "../../../vendor/alacritty/alacritty/src/renderer/mod.rs"]
mod renderer;

#[allow(
    clippy::all,
    dead_code,
    improper_ctypes,
    unsafe_op_in_unsafe_fn,
    unused_imports
)]
mod gl {
    include!(concat!(env!("OUT_DIR"), "/gl_bindings.rs"));
}

use std::borrow::Cow;
use std::collections::HashMap;
use std::ffi::{CStr, CString, c_char, c_void};
use std::num::NonZeroU32;
use std::os::fd::AsRawFd;
use std::path::PathBuf;
use std::ptr::{self, NonNull};
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

use alacritty_terminal::event::{Event, EventListener, WindowSize};
use alacritty_terminal::event_loop::{EventLoop, EventLoopSender, Msg, State};
use alacritty_terminal::grid::{Dimensions, GridCell, Scroll};
use alacritty_terminal::index::{Column, Line, Point};
use alacritty_terminal::sync::FairMutex;
use alacritty_terminal::term::cell::{Cell, Flags};
use alacritty_terminal::term::{self, Term, TermMode};
use alacritty_terminal::tty::{self, Options as PtyOptions, Shell};
use alacritty_terminal::vte::ansi::{Color, NamedColor, Rgb as TerminalRgb};
use crossfont::{Rasterize, Rasterizer, Size};
use glutin::context::PossiblyCurrentContext;
use glutin::prelude::*;
use glutin::surface::{GlSurface, Surface, SwapInterval, WindowSurface};
use renderer::rects::RenderLines;
use renderer::{GlyphCache, Renderer};
use winit::dpi::PhysicalSize;
use winit::raw_window_handle::{
    AppKitDisplayHandle, AppKitWindowHandle, RawDisplayHandle, RawWindowHandle,
};

use crate::config::font::Font;
use crate::display::SizeInfo;
use crate::display::color::Rgb;
use crate::display::content::{RenderableCell, RenderableCellExtra};

const VERSION: &[u8] = b"alacritty-0.17.0\0";
const DEFAULT_BACKGROUND: Rgb = Rgb::new(30, 30, 30);
const DEFAULT_FOREGROUND: Rgb = Rgb::new(213, 213, 213);
const PADDING_POINTS: f32 = 6.0;

type WakeCallback = unsafe extern "C" fn(*mut c_void);
type TitleCallback = unsafe extern "C" fn(*mut c_void, *const u8, usize);
type ExitCallback = unsafe extern "C" fn(*mut c_void, i32);

#[repr(C)]
pub struct CmuxAlacrittyCallbacks {
    pub user_data: *mut c_void,
    pub wake: Option<WakeCallback>,
    pub title: Option<TitleCallback>,
    pub child_exit: Option<ExitCallback>,
}

#[repr(C)]
pub struct CmuxAlacrittySurfaceConfig {
    pub ns_view: *mut c_void,
    pub width_px: u32,
    pub height_px: u32,
    pub scale_factor: f32,
    pub font_size_points: f32,
    pub font_family: *const c_char,
    pub working_directory: *const c_char,
    pub command: *const c_char,
    pub environment: *const c_char,
    pub callbacks: CmuxAlacrittyCallbacks,
}

struct CallbackState {
    user_data: usize,
    wake: Option<WakeCallback>,
    title: Option<TitleCallback>,
    child_exit: Option<ExitCallback>,
    sender: Mutex<Option<EventLoopSender>>,
    exited: AtomicBool,
    exit_code: AtomicI32,
    columns: AtomicI32,
    lines: AtomicI32,
    cell_width: AtomicI32,
    cell_height: AtomicI32,
}

impl CallbackState {
    fn wake(&self) {
        if let Some(callback) = self.wake {
            unsafe { callback(self.user_data as *mut c_void) };
        }
    }
}

#[derive(Clone)]
struct CmuxEventProxy {
    state: Arc<CallbackState>,
}

impl EventListener for CmuxEventProxy {
    fn send_event(&self, event: Event) {
        match event {
            Event::Wakeup | Event::MouseCursorDirty | Event::CursorBlinkingChange | Event::Bell => {
                self.state.wake()
            }
            Event::Title(title) => {
                if let Some(callback) = self.state.title {
                    unsafe {
                        callback(
                            self.state.user_data as *mut c_void,
                            title.as_ptr(),
                            title.len(),
                        )
                    };
                }
            }
            Event::ResetTitle => {
                if let Some(callback) = self.state.title {
                    unsafe { callback(self.state.user_data as *mut c_void, ptr::null(), 0) };
                }
            }
            Event::PtyWrite(text) => {
                if let Ok(sender) = self.state.sender.lock() {
                    if let Some(sender) = sender.as_ref() {
                        let _ = sender.send(Msg::Input(Cow::Owned(text.into_bytes())));
                    }
                }
            }
            Event::ColorRequest(index, formatter) => {
                let rgb = terminal_palette(index);
                let response = formatter(TerminalRgb {
                    r: rgb.r,
                    g: rgb.g,
                    b: rgb.b,
                });
                if let Ok(sender) = self.state.sender.lock() {
                    if let Some(sender) = sender.as_ref() {
                        let _ = sender.send(Msg::Input(Cow::Owned(response.into_bytes())));
                    }
                }
            }
            Event::TextAreaSizeRequest(formatter) => {
                let response = formatter(WindowSize {
                    num_lines: self.state.lines.load(Ordering::Relaxed).max(1) as u16,
                    num_cols: self.state.columns.load(Ordering::Relaxed).max(2) as u16,
                    cell_width: self.state.cell_width.load(Ordering::Relaxed).max(1) as u16,
                    cell_height: self.state.cell_height.load(Ordering::Relaxed).max(1) as u16,
                });
                if let Ok(sender) = self.state.sender.lock() {
                    if let Some(sender) = sender.as_ref() {
                        let _ = sender.send(Msg::Input(Cow::Owned(response.into_bytes())));
                    }
                }
            }
            Event::ChildExit(status) => {
                let code = status.code().unwrap_or(-1);
                self.state.exit_code.store(code, Ordering::Release);
                self.state.exited.store(true, Ordering::Release);
                if let Some(callback) = self.state.child_exit {
                    unsafe { callback(self.state.user_data as *mut c_void, code) };
                }
                self.state.wake();
            }
            Event::Exit => {
                self.state.exited.store(true, Ordering::Release);
                self.state.wake();
            }
            Event::ClipboardStore(_, _) | Event::ClipboardLoad(_, _) => {}
        }
    }
}

struct DisplayState {
    renderer: Renderer,
    glyph_cache: GlyphCache,
    gl_surface: Surface<WindowSurface>,
    gl_context: PossiblyCurrentContext,
    size_info: SizeInfo,
    scale_factor: f32,
    font_size_points: f32,
    font_family: String,
}

impl DisplayState {
    fn new(
        ns_view: NonNull<c_void>,
        width: u32,
        height: u32,
        scale_factor: f32,
        font_size_points: f32,
        font_family: String,
    ) -> Result<Self, String> {
        let raw_display_handle = RawDisplayHandle::AppKit(AppKitDisplayHandle::new());
        let raw_window_handle = RawWindowHandle::AppKit(AppKitWindowHandle::new(ns_view));

        let gl_display = renderer::platform::create_gl_display(
            raw_display_handle,
            Some(raw_window_handle),
            false,
        )
        .map_err(|error| format!("create OpenGL display: {error}"))?;
        let gl_config = renderer::platform::pick_gl_config(&gl_display, Some(raw_window_handle))?;
        let gl_context =
            renderer::platform::create_gl_context(&gl_display, &gl_config, Some(raw_window_handle))
                .map_err(|error| format!("create OpenGL context: {error}"))?;
        let gl_surface = renderer::platform::create_gl_surface(
            &gl_context,
            PhysicalSize::new(width, height),
            raw_window_handle,
        )
        .map_err(|error| format!("create OpenGL surface: {error}"))?;
        let gl_context = gl_context
            .make_current(&gl_surface)
            .map_err(|error| format!("activate OpenGL context: {error}"))?;
        let _ = gl_surface.set_swap_interval(&gl_context, SwapInterval::DontWait);

        let scale_factor = scale_factor.max(1.0);
        let font_size_points = font_size_points.max(6.0);
        let font = Font::new(
            font_family.clone(),
            Size::new(font_size_points * scale_factor),
        );
        let rasterizer =
            Rasterizer::new().map_err(|error| format!("create font rasterizer: {error}"))?;
        let mut glyph_cache =
            GlyphCache::new(rasterizer, &font).map_err(|error| format!("load font: {error}"))?;
        let metrics = glyph_cache.font_metrics();
        let cell_width = metrics.average_advance.floor().max(1.0) as f32;
        let cell_height = metrics.line_height.floor().max(1.0) as f32;
        let padding = PADDING_POINTS * scale_factor;
        let size_info = SizeInfo::new(
            width as f32,
            height as f32,
            cell_width,
            cell_height,
            padding,
            padding,
        );

        let mut renderer = Renderer::new(&gl_context, None)
            .map_err(|error| format!("create renderer: {error}"))?;
        renderer.resize(&size_info);
        renderer.with_loader(|mut loader| glyph_cache.load_common_glyphs(&mut loader));

        Ok(Self {
            renderer,
            glyph_cache,
            gl_surface,
            gl_context,
            size_info,
            scale_factor,
            font_size_points,
            font_family,
        })
    }

    fn make_current(&mut self) -> Result<(), String> {
        if !self.gl_context.is_current() {
            self.gl_context
                .make_current(&self.gl_surface)
                .map_err(|error| format!("activate OpenGL context: {error}"))?;
        }
        Ok(())
    }

    fn resize(&mut self, width: u32, height: u32, scale_factor: f32) -> Result<(), String> {
        self.make_current()?;
        self.gl_surface.resize(
            &self.gl_context,
            NonZeroU32::new(width.max(1)).expect("nonzero width"),
            NonZeroU32::new(height.max(1)).expect("nonzero height"),
        );

        let new_scale_factor = scale_factor.max(1.0);
        if (new_scale_factor - self.scale_factor).abs() > f32::EPSILON {
            self.scale_factor = new_scale_factor;
            let font = Font::new(
                self.font_family.clone(),
                Size::new(self.font_size_points * self.scale_factor),
            );
            self.glyph_cache
                .update_font_size(&font)
                .map_err(|error| format!("resize font: {error}"))?;
            self.renderer
                .with_loader(|mut loader| self.glyph_cache.reset_glyph_cache(&mut loader));
        }

        let metrics = self.glyph_cache.font_metrics();
        let padding = PADDING_POINTS * self.scale_factor;
        self.size_info = SizeInfo::new(
            width as f32,
            height as f32,
            metrics.average_advance.floor().max(1.0) as f32,
            metrics.line_height.floor().max(1.0) as f32,
            padding,
            padding,
        );
        self.renderer.resize(&self.size_info);
        Ok(())
    }

    fn draw(&mut self, term: &Term<CmuxEventProxy>) -> Result<(), String> {
        self.make_current()?;
        self.renderer.clear(DEFAULT_BACKGROUND, 1.0);

        // AppKit can reset the OpenGL viewport while moving or resizing a
        // layer-backed NSView. Alacritty restores it before every macOS frame.
        self.renderer.set_viewport(&self.size_info);
        let cells = renderable_cells(term);
        let mut lines = RenderLines::new();
        for cell in &cells {
            lines.update(cell);
        }
        self.renderer
            .draw_cells(&self.size_info, &mut self.glyph_cache, cells.into_iter());
        let rects = lines.rects(&self.glyph_cache.font_metrics(), &self.size_info);
        self.renderer
            .draw_rects(&self.size_info, &self.glyph_cache.font_metrics(), rects);
        self.gl_surface
            .swap_buffers(&self.gl_context)
            .map_err(|error| format!("swap OpenGL buffers: {error}"))
    }
}

pub struct CmuxAlacrittySurface {
    terminal: Arc<FairMutex<Term<CmuxEventProxy>>>,
    sender: EventLoopSender,
    io_thread: Option<JoinHandle<(EventLoop<tty::Pty, CmuxEventProxy>, State)>>,
    display: DisplayState,
    callbacks: Arc<CallbackState>,
    child_pid: u32,
    master_fd: i32,
}

impl Drop for CmuxAlacrittySurface {
    fn drop(&mut self) {
        let _ = self.sender.send(Msg::Shutdown);
        if let Some(thread) = self.io_thread.take() {
            let _ = thread.join();
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn cmux_alacritty_version() -> *const c_char {
    VERSION.as_ptr().cast()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_alacritty_surface_new(
    config: *const CmuxAlacrittySurfaceConfig,
) -> *mut CmuxAlacrittySurface {
    clear_last_error();
    let result = unsafe { create_surface(config) };
    match result {
        Ok(surface) => Box::into_raw(Box::new(surface)),
        Err(error) => {
            set_last_error(error);
            ptr::null_mut()
        }
    }
}

unsafe fn create_surface(
    config: *const CmuxAlacrittySurfaceConfig,
) -> Result<CmuxAlacrittySurface, String> {
    let config = unsafe { config.as_ref() }.ok_or("missing surface configuration")?;
    let ns_view = NonNull::new(config.ns_view).ok_or("missing NSView")?;
    let width = config.width_px.max(1);
    let height = config.height_px.max(1);
    let scale_factor = config.scale_factor.max(1.0);
    let font_size_points = config.font_size_points.max(6.0);
    let font_family = unsafe { optional_string(config.font_family) }
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| String::from("Menlo"));
    let working_directory =
        unsafe { optional_string(config.working_directory) }.filter(|value| !value.is_empty());
    let command = unsafe { optional_string(config.command) }.filter(|value| !value.is_empty());
    let environment = unsafe { optional_string(config.environment) }.unwrap_or_default();

    let display = DisplayState::new(
        ns_view,
        width,
        height,
        scale_factor,
        font_size_points,
        font_family,
    )?;
    let callback_state = Arc::new(CallbackState {
        user_data: config.callbacks.user_data as usize,
        wake: config.callbacks.wake,
        title: config.callbacks.title,
        child_exit: config.callbacks.child_exit,
        sender: Mutex::new(None),
        exited: AtomicBool::new(false),
        exit_code: AtomicI32::new(0),
        columns: AtomicI32::new(display.size_info.columns() as i32),
        lines: AtomicI32::new(display.size_info.screen_lines() as i32),
        cell_width: AtomicI32::new(display.size_info.cell_width() as i32),
        cell_height: AtomicI32::new(display.size_info.cell_height() as i32),
    });
    let event_proxy = CmuxEventProxy {
        state: Arc::clone(&callback_state),
    };
    let terminal = Term::new(Default::default(), &display.size_info, event_proxy.clone());
    let terminal = Arc::new(FairMutex::new(terminal));

    let shell = match command {
        Some(command) => Shell::new(String::from("/bin/zsh"), vec![String::from("-lc"), command]),
        None => {
            let shell = std::env::var("SHELL").unwrap_or_else(|_| String::from("/bin/zsh"));
            Shell::new(shell, vec![String::from("-l")])
        }
    };
    let mut environment_map = parse_environment(&environment);
    environment_map
        .entry(String::from("TERM"))
        .or_insert_with(|| String::from("xterm-256color"));
    environment_map
        .entry(String::from("COLORTERM"))
        .or_insert_with(|| String::from("truecolor"));
    let pty_options = PtyOptions {
        shell: Some(shell),
        working_directory: working_directory.map(PathBuf::from),
        drain_on_exit: true,
        env: environment_map,
    };
    let window_size = WindowSize {
        num_lines: display.size_info.screen_lines() as u16,
        num_cols: display.size_info.columns() as u16,
        cell_width: display.size_info.cell_width() as u16,
        cell_height: display.size_info.cell_height() as u16,
    };
    let pty = tty::new(&pty_options, window_size, config.callbacks.user_data as u64)
        .map_err(|error| format!("spawn PTY: {error}"))?;
    let child_pid = pty.child().id();
    let master_fd = pty.file().as_raw_fd();
    let event_loop = EventLoop::new(
        Arc::clone(&terminal),
        event_proxy,
        pty,
        pty_options.drain_on_exit,
        false,
    )
    .map_err(|error| format!("create PTY event loop: {error}"))?;
    let sender = event_loop.channel();
    if let Ok(mut callback_sender) = callback_state.sender.lock() {
        *callback_sender = Some(sender.clone());
    }
    let io_thread = event_loop.spawn();

    Ok(CmuxAlacrittySurface {
        terminal,
        sender,
        io_thread: Some(io_thread),
        display,
        callbacks: callback_state,
        child_pid,
        master_fd,
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_alacritty_surface_free(surface: *mut CmuxAlacrittySurface) {
    if !surface.is_null() {
        drop(unsafe { Box::from_raw(surface) });
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_alacritty_surface_draw(surface: *mut CmuxAlacrittySurface) -> bool {
    let Some(surface) = (unsafe { surface.as_mut() }) else {
        return false;
    };
    let terminal = surface.terminal.lock();
    match surface.display.draw(&terminal) {
        Ok(()) => true,
        Err(error) => {
            set_last_error(error);
            false
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_alacritty_surface_resize(
    surface: *mut CmuxAlacrittySurface,
    width_px: u32,
    height_px: u32,
    scale_factor: f32,
) -> bool {
    let Some(surface) = (unsafe { surface.as_mut() }) else {
        return false;
    };
    if let Err(error) = surface
        .display
        .resize(width_px.max(1), height_px.max(1), scale_factor)
    {
        set_last_error(error);
        return false;
    }

    let window_size = WindowSize {
        num_lines: surface.display.size_info.screen_lines() as u16,
        num_cols: surface.display.size_info.columns() as u16,
        cell_width: surface.display.size_info.cell_width() as u16,
        cell_height: surface.display.size_info.cell_height() as u16,
    };
    {
        let mut terminal = surface.terminal.lock();
        terminal.resize(surface.display.size_info);
    }
    surface
        .callbacks
        .columns
        .store(window_size.num_cols.into(), Ordering::Relaxed);
    surface
        .callbacks
        .lines
        .store(window_size.num_lines.into(), Ordering::Relaxed);
    surface
        .callbacks
        .cell_width
        .store(window_size.cell_width.into(), Ordering::Relaxed);
    surface
        .callbacks
        .cell_height
        .store(window_size.cell_height.into(), Ordering::Relaxed);
    let _ = surface.sender.send(Msg::Resize(window_size));
    surface.callbacks.wake();
    true
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_alacritty_surface_write(
    surface: *mut CmuxAlacrittySurface,
    bytes: *const u8,
    length: usize,
) -> bool {
    let Some(surface) = (unsafe { surface.as_ref() }) else {
        return false;
    };
    if bytes.is_null() || length == 0 {
        return true;
    }
    let bytes = unsafe { std::slice::from_raw_parts(bytes, length) }.to_vec();
    surface.sender.send(Msg::Input(Cow::Owned(bytes))).is_ok()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_alacritty_surface_key(
    surface: *mut CmuxAlacrittySurface,
    key: u32,
    modifiers: u32,
) -> bool {
    let Some(surface) = (unsafe { surface.as_ref() }) else {
        return false;
    };
    let application_cursor = surface
        .terminal
        .lock()
        .mode()
        .contains(TermMode::APP_CURSOR);
    let Some(bytes) = key_bytes(key, modifiers, application_cursor) else {
        return false;
    };
    surface.sender.send(Msg::Input(Cow::Owned(bytes))).is_ok()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_alacritty_surface_scroll(
    surface: *mut CmuxAlacrittySurface,
    lines: i32,
) -> bool {
    let Some(surface) = (unsafe { surface.as_ref() }) else {
        return false;
    };
    surface.terminal.lock().scroll_display(Scroll::Delta(lines));
    surface.callbacks.wake();
    true
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_alacritty_surface_set_focus(
    surface: *mut CmuxAlacrittySurface,
    focused: bool,
) -> bool {
    let Some(surface) = (unsafe { surface.as_ref() }) else {
        return false;
    };
    surface.terminal.lock().is_focused = focused;
    surface.callbacks.wake();
    true
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_alacritty_surface_screen_text(
    surface: *mut CmuxAlacrittySurface,
    include_scrollback: bool,
    length: *mut usize,
) -> *mut c_char {
    let Some(surface) = (unsafe { surface.as_ref() }) else {
        return ptr::null_mut();
    };
    let terminal = surface.terminal.lock();
    let display_offset = terminal.grid().display_offset();
    let top = if include_scrollback {
        terminal.topmost_line()
    } else {
        Line(-(display_offset as i32))
    };
    let bottom = if include_scrollback {
        terminal.bottommost_line()
    } else {
        top + terminal.screen_lines().saturating_sub(1)
    };
    let text = terminal.bounds_to_string(
        Point::new(top, Column(0)),
        Point::new(bottom, terminal.last_column()),
    );
    let Ok(text) = CString::new(text) else {
        return ptr::null_mut();
    };
    if let Some(length) = unsafe { length.as_mut() } {
        *length = text.as_bytes().len();
    }
    text.into_raw()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_alacritty_string_free(string: *mut c_char) {
    if !string.is_null() {
        drop(unsafe { CString::from_raw(string) });
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_alacritty_surface_child_pid(
    surface: *const CmuxAlacrittySurface,
) -> u32 {
    unsafe { surface.as_ref() }
        .map(|surface| surface.child_pid)
        .unwrap_or_default()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_alacritty_surface_process_exited(
    surface: *const CmuxAlacrittySurface,
) -> bool {
    unsafe { surface.as_ref() }
        .map(|surface| surface.callbacks.exited.load(Ordering::Acquire))
        .unwrap_or(true)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_alacritty_surface_needs_confirm_close(
    surface: *const CmuxAlacrittySurface,
) -> bool {
    let Some(surface) = (unsafe { surface.as_ref() }) else {
        return false;
    };
    if surface.callbacks.exited.load(Ordering::Acquire) {
        return false;
    }
    let foreground_process_group = unsafe { libc::tcgetpgrp(surface.master_fd) };
    foreground_process_group > 0 && foreground_process_group as u32 != surface.child_pid
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_alacritty_surface_grid_size(
    surface: *const CmuxAlacrittySurface,
    columns: *mut u32,
    rows: *mut u32,
    cell_width: *mut u32,
    cell_height: *mut u32,
) -> bool {
    let Some(surface) = (unsafe { surface.as_ref() }) else {
        return false;
    };
    if let Some(columns) = unsafe { columns.as_mut() } {
        *columns = surface.display.size_info.columns() as u32;
    }
    if let Some(rows) = unsafe { rows.as_mut() } {
        *rows = surface.display.size_info.screen_lines() as u32;
    }
    if let Some(cell_width) = unsafe { cell_width.as_mut() } {
        *cell_width = surface.display.size_info.cell_width() as u32;
    }
    if let Some(cell_height) = unsafe { cell_height.as_mut() } {
        *cell_height = surface.display.size_info.cell_height() as u32;
    }
    true
}

#[unsafe(no_mangle)]
pub extern "C" fn cmux_alacritty_last_error() -> *const c_char {
    let Ok(error) = last_error().lock() else {
        return ptr::null();
    };
    error
        .as_ref()
        .map(|error| error.as_ptr())
        .unwrap_or(ptr::null())
}

unsafe fn optional_string(pointer: *const c_char) -> Option<String> {
    if pointer.is_null() {
        return None;
    }
    Some(
        unsafe { CStr::from_ptr(pointer) }
            .to_string_lossy()
            .into_owned(),
    )
}

fn parse_environment(environment: &str) -> HashMap<String, String> {
    serde_json::from_str(environment).unwrap_or_default()
}

fn renderable_cells(terminal: &Term<CmuxEventProxy>) -> Vec<RenderableCell> {
    let content = terminal.renderable_content();
    let display_offset = content.display_offset;
    let cursor_point = term::point_to_viewport(display_offset, content.cursor.point);
    let cursor_visible = content.cursor.shape != alacritty_terminal::vte::ansi::CursorShape::Hidden;
    let dynamic_colors = content.colors;
    let mut cells = Vec::with_capacity(terminal.columns().saturating_mul(terminal.screen_lines()));

    for indexed in content.display_iter {
        let Some(point) = term::point_to_viewport(display_offset, indexed.point) else {
            continue;
        };
        if point.line >= terminal.screen_lines() {
            continue;
        }

        let cell: &Cell = indexed.cell;
        let is_cursor = cursor_visible && cursor_point == Some(point);
        if !is_cursor
            && cell.is_empty()
            && !cell
                .flags
                .intersects(Flags::ALL_UNDERLINES | Flags::STRIKEOUT)
        {
            continue;
        }
        if cell.flags.contains(Flags::WIDE_CHAR_SPACER) {
            continue;
        }

        let mut foreground = resolve_color(cell.fg, dynamic_colors, cell.flags, true);
        let mut background = resolve_color(cell.bg, dynamic_colors, cell.flags, false);
        if cell.flags.contains(Flags::INVERSE) {
            std::mem::swap(&mut foreground, &mut background);
        }
        if is_cursor {
            std::mem::swap(&mut foreground, &mut background);
        }
        let underline = cell
            .underline_color()
            .map(|color| resolve_color(color, dynamic_colors, cell.flags, true))
            .unwrap_or(foreground);
        let character = if cell.flags.contains(Flags::HIDDEN) {
            ' '
        } else {
            cell.c
        };
        let extra = cell
            .zerowidth()
            .filter(|characters| !characters.is_empty())
            .map(|characters| {
                Box::new(RenderableCellExtra {
                    zerowidth: Some(characters.to_vec()),
                })
            });
        cells.push(RenderableCell {
            character,
            point,
            fg: foreground,
            bg: background,
            bg_alpha: 1.0,
            underline,
            flags: cell.flags,
            extra,
        });
    }

    cells
}

fn resolve_color(
    color: Color,
    dynamic_colors: &alacritty_terminal::term::color::Colors,
    flags: Flags,
    foreground: bool,
) -> Rgb {
    let mut index = match color {
        Color::Spec(color) => {
            return Rgb::new(color.r, color.g, color.b);
        }
        Color::Indexed(index) => index as usize,
        Color::Named(named) => {
            let named = if foreground && flags.contains(Flags::BOLD) {
                named.to_bright()
            } else if flags.contains(Flags::DIM) {
                named.to_dim()
            } else {
                named
            };
            named as usize
        }
    };
    if index >= alacritty_terminal::term::color::COUNT {
        index = NamedColor::Foreground as usize;
    }
    if let Some(color) = dynamic_colors[index] {
        return Rgb::new(color.r, color.g, color.b);
    }
    terminal_palette(index)
}

fn terminal_palette(index: usize) -> Rgb {
    const NORMAL: [Rgb; 8] = [
        Rgb::new(0, 0, 0),
        Rgb::new(205, 49, 49),
        Rgb::new(13, 188, 121),
        Rgb::new(229, 229, 16),
        Rgb::new(36, 114, 200),
        Rgb::new(188, 63, 188),
        Rgb::new(17, 168, 205),
        Rgb::new(229, 229, 229),
    ];
    const BRIGHT: [Rgb; 8] = [
        Rgb::new(102, 102, 102),
        Rgb::new(241, 76, 76),
        Rgb::new(35, 209, 139),
        Rgb::new(245, 245, 67),
        Rgb::new(59, 142, 234),
        Rgb::new(214, 112, 214),
        Rgb::new(41, 184, 219),
        Rgb::new(255, 255, 255),
    ];

    match index {
        0..=7 => NORMAL[index],
        8..=15 => BRIGHT[index - 8],
        16..=231 => {
            let value = index - 16;
            let component = |component: usize| {
                if component == 0 {
                    0
                } else {
                    (component * 40 + 55) as u8
                }
            };
            Rgb::new(
                component(value / 36),
                component((value / 6) % 6),
                component(value % 6),
            )
        }
        232..=255 => {
            let value = ((index - 232) * 10 + 8) as u8;
            Rgb::new(value, value, value)
        }
        value if value == NamedColor::Background as usize => DEFAULT_BACKGROUND,
        value if value == NamedColor::Cursor as usize => DEFAULT_FOREGROUND,
        value if value == NamedColor::BrightForeground as usize => Rgb::new(255, 255, 255),
        value if value == NamedColor::DimForeground as usize => Rgb::new(140, 140, 140),
        259..=266 => {
            let base = NORMAL[index - 259];
            Rgb::new(
                (f32::from(base.r) * 0.66) as u8,
                (f32::from(base.g) * 0.66) as u8,
                (f32::from(base.b) * 0.66) as u8,
            )
        }
        _ => DEFAULT_FOREGROUND,
    }
}

fn key_bytes(key: u32, modifiers: u32, application_cursor: bool) -> Option<Vec<u8>> {
    const SHIFT: u32 = 1 << 0;
    const CONTROL: u32 = 1 << 1;
    const ALT: u32 = 1 << 2;
    let mut bytes: Vec<u8> = match key {
        0 => vec![b'\r'],
        1 => vec![b'\t'],
        2 => vec![0x7f],
        3 => vec![0x1b],
        4 => cursor_sequence(b'A', application_cursor),
        5 => cursor_sequence(b'B', application_cursor),
        6 => cursor_sequence(b'D', application_cursor),
        7 => cursor_sequence(b'C', application_cursor),
        8 => if application_cursor {
            b"\x1bOH"
        } else {
            b"\x1b[H"
        }
        .to_vec(),
        9 => if application_cursor {
            b"\x1bOF"
        } else {
            b"\x1b[F"
        }
        .to_vec(),
        10 => b"\x1b[5~".to_vec(),
        11 => b"\x1b[6~".to_vec(),
        12 => b"\x1b[3~".to_vec(),
        13 => b"\x1b[2~".to_vec(),
        14..=25 => function_key_sequence(key - 13)?,
        100..=125 if modifiers & CONTROL != 0 => {
            vec![((key - 100) as u8 + b'a') & 0x1f]
        }
        _ => return None,
    };

    if modifiers & SHIFT != 0 && key == 1 {
        bytes = b"\x1b[Z".to_vec();
    }
    if modifiers & ALT != 0 && !bytes.starts_with(&[0x1b]) {
        bytes.insert(0, 0x1b);
    }
    Some(bytes)
}

fn cursor_sequence(final_byte: u8, application_cursor: bool) -> Vec<u8> {
    if application_cursor {
        vec![0x1b, b'O', final_byte]
    } else {
        vec![0x1b, b'[', final_byte]
    }
}

fn function_key_sequence(number: u32) -> Option<Vec<u8>> {
    let sequence = match number {
        1 => "\x1bOP",
        2 => "\x1bOQ",
        3 => "\x1bOR",
        4 => "\x1bOS",
        5 => "\x1b[15~",
        6 => "\x1b[17~",
        7 => "\x1b[18~",
        8 => "\x1b[19~",
        9 => "\x1b[20~",
        10 => "\x1b[21~",
        11 => "\x1b[23~",
        12 => "\x1b[24~",
        _ => return None,
    };
    Some(sequence.as_bytes().to_vec())
}

fn last_error() -> &'static Mutex<Option<CString>> {
    static LAST_ERROR: std::sync::OnceLock<Mutex<Option<CString>>> = std::sync::OnceLock::new();
    LAST_ERROR.get_or_init(|| Mutex::new(None))
}

fn clear_last_error() {
    if let Ok(mut error) = last_error().lock() {
        *error = None;
    }
}

fn set_last_error(error: String) {
    let sanitized = error.replace('\0', "\u{fffd}");
    if let Ok(mut last_error) = last_error().lock() {
        *last_error = CString::new(sanitized).ok();
    }
}
