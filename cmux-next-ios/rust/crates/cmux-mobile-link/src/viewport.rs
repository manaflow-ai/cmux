//! Viewport sync, phone side (default off; `CMUX_MOBILE_VIEWPORT_SYNC=1`).
//!
//! On a WireGuard link the host may send a surface's screen as state diffs
//! in overlay datagrams to port [`PORT`] (`cmux_terminal_projection::sync`)
//! instead of the raw output on the daemon stream. The phone turns each new
//! state into VT bytes ([`render_screen`]) and hands them to Swift as a
//! synthetic `output` line, so the app's projection draws it unchanged.
//!
//! The daemon stream says what is synced: `viewport-sync` (surface, epoch)
//! starts it, `viewport-path` says whether the datagrams or the stream carry
//! the screen right now, `viewport-history` carries rows that scrolled off,
//! `viewport-sync-end` stops it. [`ViewportReceiver`] wraps the channel's
//! receiver: it swallows those lines and injects the rendered ones in order.
//! One [`PhoneViewport`] per link owns the 7424 socket every channel shares,
//! demuxed by the epoch in each datagram.
//!
//! What a [`ScreenState`] does not carry (autowrap, the scroll region, origin
//! and insert modes, the character set, the pen, a pending wrap) the bytes
//! normalize: autowrap on (where a spacer is drawn), no region, origin and
//! insert off, ASCII, SGR 0.

use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError, Weak};

use base64::Engine as _;
use bytes::Bytes;
use cmux_terminal_projection::Terminal;
use cmux_terminal_projection::style::Style;
use cmux_terminal_projection::sync::{
    self, KITTY_FLAGS_SHIFT, MODE_ALT_SCROLL, MODE_APP_CURSOR, MODE_BRACKETED_PASTE, MODE_CURSOR_BLINK,
    MODE_FOCUS_EVENTS, MODE_GRAPHEME_CLUSTER, MODE_KEYPAD_APP, MODE_MOUSE_ANY, MODE_MOUSE_BUTTON,
    MODE_MOUSE_NORMAL, MODE_MOUSE_SGR, MODE_MOUSE_SGR_PIXELS, MODE_MOUSE_URXVT, MODE_MOUSE_UTF8,
    MODE_MOUSE_X10, MODE_REVERSE_VIDEO, ScreenState, SyncCell, SyncReceiver, SyncStyle,
};
use cmux_terminal_projection::terminal::{SPACER_HEAD, WIDE, WIDE_TAIL};
use cmux_wg::{Priority, WgNet};
use serde_json::Value;
use tokio::sync::Notify;

use crate::dial::Overlay;
use crate::link::{ChannelEvent, ChannelReceiver};

/// The gate, on each side: `1` turns viewport sync on.
pub const ENV: &str = "CMUX_MOBILE_VIEWPORT_SYNC";
/// The overlay UDP port both sides bind for viewport sync.
pub const PORT: u16 = 7424;

/// Whether this process's gate is on (`CMUX_MOBILE_VIEWPORT_SYNC=1`).
pub fn enabled() -> bool {
    std::env::var(ENV).is_ok_and(|value| value == "1")
}

// ---------------------------------------------------------------------------
// Rendering.

/// The DEC private modes a [`ScreenState`] carries and their bits (the
/// projection's own table, which it keeps private).
const PRIVATE_MODES: &[(u16, u32)] = &[
    (1, MODE_APP_CURSOR),
    (5, MODE_REVERSE_VIDEO),
    (9, MODE_MOUSE_X10),
    (12, MODE_CURSOR_BLINK),
    (1000, MODE_MOUSE_NORMAL),
    (1002, MODE_MOUSE_BUTTON),
    (1003, MODE_MOUSE_ANY),
    (1004, MODE_FOCUS_EVENTS),
    (1005, MODE_MOUSE_UTF8),
    (1006, MODE_MOUSE_SGR),
    (1007, MODE_ALT_SCROLL),
    (1015, MODE_MOUSE_URXVT),
    (1016, MODE_MOUSE_SGR_PIXELS),
    (2004, MODE_BRACKETED_PASTE),
];
/// The kitty keyboard flags' width in [`ScreenState::modes`].
const KITTY_MASK: u32 = 0x1f;
/// What every rendering starts with: insert off, origin off, G0 ASCII and
/// shifted in (what the painting assumes).
const PROLOGUE: &[u8] = b"\x1b[4l\x1b[?6l\x0f\x1b(B";
/// A wide glyph, printed to leave a spacer or a blank in a given style.
const WIDE_GLYPH: &str = "\u{4e2d}";

/// VT bytes that make a terminal showing `prev` (None: unknown, repaint all) show `next`.
pub fn render_screen(prev: Option<&ScreenState>, next: &ScreenState) -> Vec<u8> {
    if prev == Some(next) {
        return Vec::new();
    }
    // A state of another grid or screen says nothing about what is shown.
    let prev = prev.filter(|p| {
        p.cols == next.cols
            && p.rows == next.rows
            && p.alternate == next.alternate
            && p.cells.len() == next.cells.len()
    });
    let mut paint = Painter::new(next.cols);
    paint.out.extend_from_slice(PROLOGUE);
    if prev.is_none() {
        // 1049 is a no-op when that screen is already up; leaving the
        // alternate one restores a cursor the end moves anyway.
        paint.out.extend_from_slice(if next.alternate { b"\x1b[?1049h" } else { b"\x1b[?1049l" });
    }
    // Clusters print as one glyph only with 2027 on; the end sets `next`'s.
    let clustering = prev.is_some_and(|p| p.modes & MODE_GRAPHEME_CLUSTER != 0);
    if !clustering {
        paint.out.extend_from_slice(b"\x1b[?2027h");
    }
    paint_rows(&mut paint, prev, next);
    write_modes(&mut paint.out, prev, next);
    if paint.link.as_deref() != Some("") {
        write_osc8(&mut paint.out, "");
    }
    if paint.pen != Some(Style::default()) {
        Style::default().write_sgr(&mut paint.out);
    }
    if prev.is_none_or(|p| p.cursor_visible != next.cursor_visible) {
        paint.out.extend_from_slice(if next.cursor_visible { b"\x1b[?25h" } else { b"\x1b[?25l" });
    }
    if prev.is_none_or(|p| p.cursor_shape != next.cursor_shape) {
        paint.out.extend_from_slice(format!("\x1b[{} q", next.cursor_shape).as_bytes());
    }
    let (x, y) = next.cursor;
    let x = x.min(next.cols.saturating_sub(1));
    let y = y.min(next.rows.saturating_sub(1));
    paint.out.extend_from_slice(format!("\x1b[{};{}H", u32::from(y) + 1, u32::from(x) + 1).as_bytes());
    paint.out
}

/// VT bytes that push `rows` (HistoryTracker::take_new_rows output) into a terminal's scrollback
/// without leaving them on its screen, then repaint `screen` in full.
pub fn render_history(rows: &[u8], screen: &ScreenState) -> Vec<u8> {
    let mut out = push_history(rows, screen.cols, screen.rows);
    out.extend_from_slice(&render_screen(None, screen));
    out
}

/// `rows` into the scrollback of a terminal of `cols` x `height` (its primary
/// screen), leaving that screen blank (when there were rows).
fn push_history(rows: &[u8], cols: u16, height: u16) -> Vec<u8> {
    let mut out = b"\x1b[?1049l\x1b[r".to_vec();
    out.extend_from_slice(PROLOGUE);
    Style::default().write_sgr(&mut out);
    // RIS: the host's scrollback was cleared; the rows after it start over.
    let rows = match rows.strip_prefix(b"\x1bc") {
        Some(rest) => {
            out.extend_from_slice(b"\x1b[3J");
            rest
        }
        None => rows,
    };
    if rows.is_empty() {
        return out;
    }
    // Write them on a cleared screen (ED 0 keeps the screen out of the
    // scrollback); what overflows scrolls into it, and the rows still on
    // the screen are scrolled up after it.
    out.extend_from_slice(b"\x1b[H\x1b[J");
    out.extend_from_slice(rows);
    let mut scratch = Terminal::new(usize::from(cols.max(1)), usize::from(height.max(1)), 0);
    for &byte in rows {
        scratch.advance(byte);
    }
    let (x, y) = scratch.cursor();
    let on_screen = y + usize::from(x > 0);
    if on_screen > 0 {
        out.extend_from_slice(format!("\x1b[{on_screen}S").as_bytes());
    }
    Style::default().write_sgr(&mut out);
    out.extend_from_slice(b"\x1b[H");
    out
}

/// Bytes being written and what they leave the terminal in.
struct Painter {
    out: Vec<u8>,
    cols: u16,
    /// Where the cursor is (None: unknown or waiting to wrap).
    at: Option<(u16, u16)>,
    /// The SGR pen (None: unknown).
    pen: Option<Style>,
    /// The OSC 8 link the pen is in ("" none; None: unknown).
    link: Option<String>,
}

impl Painter {
    fn new(cols: u16) -> Self {
        Self { out: Vec::new(), cols, at: None, pen: None, link: None }
    }

    fn goto(&mut self, x: u16, y: u16) {
        if self.at != Some((x, y)) {
            self.out.extend_from_slice(format!("\x1b[{};{}H", u32::from(y) + 1, u32::from(x) + 1).as_bytes());
            self.at = Some((x, y));
        }
    }

    fn sgr(&mut self, style: Style) {
        if self.pen != Some(style) {
            style.write_sgr(&mut self.out);
            self.pen = Some(style);
        }
    }

    fn pen(&mut self, style: &SyncStyle) {
        self.sgr(style.sgr());
        if self.link.as_deref() != Some(style.link.as_str()) {
            write_osc8(&mut self.out, &style.link);
            self.link = Some(style.link.clone());
        }
    }

    /// Prints `text` (one glyph `width` columns wide) at (x, y).
    fn print(&mut self, x: u16, y: u16, text: &str, width: u16) {
        self.goto(x, y);
        self.out.extend_from_slice(text.as_bytes());
        let next = x + width;
        // A cluster may move the cursor its own way; the last column waits to wrap.
        self.at = if next < self.cols && text.chars().nth(1).is_none() { Some((next, y)) } else { None };
    }

    /// `n` blanks from (x, y) in `style`'s erased form (ECH).
    fn erase(&mut self, x: u16, y: u16, n: u16, style: Style) {
        self.goto(x, y);
        self.sgr(style);
        self.out.extend_from_slice(format!("\x1b[{n}X").as_bytes());
    }

    fn raw(&mut self, bytes: &[u8]) {
        self.out.extend_from_slice(bytes);
        self.at = None;
    }
}

fn write_osc8(out: &mut Vec<u8>, link: &str) {
    out.extend_from_slice(b"\x1b]8;");
    if link.is_empty() {
        out.push(b';');
    } else {
        out.extend_from_slice(link.as_bytes());
    }
    out.extend_from_slice(b"\x1b\\");
}

/// A blank an erase (ECH) leaves: background only, no link.
fn erasable(style: &SyncStyle) -> bool {
    style.link.is_empty() && style.sgr() == style.sgr().erased()
}

fn is_blank(cell: &SyncCell) -> bool {
    cell.text.is_empty() && cell.width != WIDE && cell.width != WIDE_TAIL
}

/// Every row of `next` that differs from `prev` (all of them without one),
/// from its first differing cell to its end.
fn paint_rows(paint: &mut Painter, prev: Option<&ScreenState>, next: &ScreenState) {
    let (cols, rows) = (next.cols, next.rows);
    let mut force_next = false;
    for y in 0..rows {
        let row = next.row(y);
        if row.len() != usize::from(cols) {
            continue;
        }
        let old = prev.map(|p| p.row(y)).filter(|old| old.len() == row.len());
        let forced = std::mem::take(&mut force_next);
        let first = if forced {
            Some(0)
        } else {
            match old {
                Some(old) => old.iter().zip(row).position(|(a, b)| a != b),
                None => Some(0),
            }
        };
        let Some(first) = first else { continue };
        let mut start = u16::try_from(first).unwrap_or(0);
        // Never print into a wide glyph's tail: its head goes with it.
        let tail_at =
            |cells: &[SyncCell], x: u16| cells.get(usize::from(x)).is_some_and(|c| c.width == WIDE_TAIL);
        if start > 0 && (tail_at(row, start) || old.is_some_and(|old| tail_at(old, start))) {
            start -= 1;
        }
        let last = row.last();
        let spacer = cols >= 2 && last.is_some_and(|c| c.width == SPACER_HEAD);
        let mut spacer_drawn = false;
        if spacer && (forced || old.is_none_or(|old| old.last() != last)) {
            // A spacer is what a wide glyph leaves when it wraps from the
            // last column: print one there, in the spacer's (erased) style.
            let style = last.map(|c| c.style.sgr()).unwrap_or_default();
            if y + 1 < rows {
                paint.raw(b"\x1b[?7h\x1b[r");
                paint.sgr(style);
                paint.print(cols - 1, y, WIDE_GLYPH, 2);
                // The glyph landed at the start of the next row.
                force_next = true;
                spacer_drawn = true;
            } else if rows >= 3 {
                // The last row: a region above it keeps the wrap from scrolling.
                paint.raw(format!("\x1b[?7h\x1b[1;{}r", rows - 1).as_bytes());
                paint.sgr(style);
                paint.print(cols - 1, y, WIDE_GLYPH, 2);
                paint.raw(b"\x1b[r");
                // The glyph landed at the start of this row.
                start = 0;
                spacer_drawn = true;
            }
        } else if spacer {
            spacer_drawn = true;
        }
        paint_row(paint, y, row, start, spacer_drawn);
    }
}

/// Paints `row` (row `y`) from column `start`. `spacer_drawn`: its last
/// cell is a spacer already on the terminal.
fn paint_row(paint: &mut Painter, y: u16, row: &[SyncCell], start: u16, spacer_drawn: bool) {
    let cols = paint.cols;
    let mut x = start;
    while x < cols {
        let Some(cell) = row.get(usize::from(x)) else { break };
        if cell.width == WIDE_TAIL || (spacer_drawn && x + 1 == cols && cell.width == SPACER_HEAD) {
            x += 1;
            continue;
        }
        if !is_blank(cell) {
            paint.pen(&cell.style);
            paint.print(x, y, &cell.text, if cell.width == WIDE { 2 } else { 1 });
            x += 1;
            continue;
        }
        let next = row.get(usize::from(x) + 1);
        let next_is_drawn_spacer =
            spacer_drawn && x + 2 == cols && next.is_some_and(|c| c.width == SPACER_HEAD);
        if erasable(&cell.style) || next.is_none() || next_is_drawn_spacer {
            // An erase run (a blank in another style at the end of a row is
            // left in its erased form).
            let style = cell.style.sgr().erased();
            let mut n = 1u16;
            while let Some(more) = row.get(usize::from(x + n))
                && x + n < cols
                && is_blank(more)
                && more.width != SPACER_HEAD
                && erasable(&more.style)
                && more.style.sgr() == style
            {
                n += 1;
            }
            paint.erase(x, y, n, style);
            x += n;
        } else {
            // A blank in a full style (what a wide glyph's other half
            // becomes): a wide glyph in that style, whose tail the next
            // cell's paint overwrites, leaving the head blank in it.
            paint.pen(&cell.style);
            paint.print(x, y, WIDE_GLYPH, 2);
            x += 1;
        }
    }
}

/// The modes, keypad, kitty flags and clustering that differ from `prev`
/// (all without one). 2027 is on when this runs.
fn write_modes(out: &mut Vec<u8>, prev: Option<&ScreenState>, next: &ScreenState) {
    let changed = |bit: u32| prev.is_none_or(|p| p.modes & bit != next.modes & bit);
    for &(mode, bit) in PRIVATE_MODES {
        if changed(bit) {
            let on = next.modes & bit != 0;
            out.extend_from_slice(format!("\x1b[?{mode}{}", if on { 'h' } else { 'l' }).as_bytes());
        }
    }
    if changed(MODE_KEYPAD_APP) {
        out.extend_from_slice(if next.modes & MODE_KEYPAD_APP != 0 { b"\x1b=" } else { b"\x1b>" });
    }
    let kitty = (next.modes >> KITTY_FLAGS_SHIFT) & KITTY_MASK;
    if prev.is_none_or(|p| (p.modes >> KITTY_FLAGS_SHIFT) & KITTY_MASK != kitty) {
        out.extend_from_slice(format!("\x1b[={kitty}u").as_bytes());
    }
    if next.modes & MODE_GRAPHEME_CLUSTER == 0 {
        out.extend_from_slice(b"\x1b[?2027l");
    }
}

// ---------------------------------------------------------------------------
// The phone receiver.

/// One synced surface's receiver, shared by the socket task and the channel.
#[derive(Clone)]
struct Route {
    state: Arc<Mutex<SyncReceiver>>,
    wake: Arc<Notify>,
}

type Routes = Mutex<HashMap<u32, Route>>;

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

struct Hub {
    /// The overlay's stack, held weakly so the hub never keeps a tunnel up.
    net: Option<Weak<WgNet>>,
    /// The gate is on and the link has an overlay: ask the host for sync.
    requests: bool,
    routes: Arc<Routes>,
    /// The socket task (bound lazily, on the first synced surface).
    task: Mutex<Option<tokio::task::JoinHandle<()>>>,
}

impl Drop for Hub {
    fn drop(&mut self) {
        if let Some(task) = self.task.get_mut().unwrap_or_else(PoisonError::into_inner).take() {
            task.abort();
        }
    }
}

/// A link's viewport sync, phone side: the [`PORT`] socket (bound on first
/// use, acks to each datagram's source) and the receivers it feeds, by
/// epoch. Cheap to clone; every clone is the same hub.
#[derive(Clone)]
pub struct PhoneViewport {
    inner: Arc<Hub>,
}

impl std::fmt::Debug for PhoneViewport {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PhoneViewport").field("requests", &self.inner.requests).finish_non_exhaustive()
    }
}

impl PhoneViewport {
    /// The hub for a link riding `overlay` (`Connected::overlay`); `enabled`
    /// is the gate ([`enabled`] in the app). Without an overlay it binds
    /// nothing and asks for nothing, but still reads viewport lines and
    /// takes datagrams through [`PhoneViewport::on_datagram`] (tests).
    pub fn new(overlay: Option<&Overlay>, enabled: bool) -> Self {
        let net = overlay.filter(|_| enabled).map(|overlay| Arc::downgrade(&overlay.net));
        Self {
            inner: Arc::new(Hub {
                requests: net.is_some(),
                net,
                routes: Arc::new(Mutex::new(HashMap::new())),
                task: Mutex::new(None),
            }),
        }
    }

    /// Whether daemon channels ask the host for viewport sync.
    pub fn requests_sync(&self) -> bool {
        self.inner.requests
    }

    /// Merges this phone's daemon `open` args into `args` (an object):
    /// `"pseq": true` always, `"viewport_sync": 1` when sync is requested.
    pub fn merge_daemon_args(&self, args: &mut Value) {
        let Some(map) = args.as_object_mut() else { return };
        map.insert("pseq".into(), Value::Bool(true));
        if self.requests_sync() {
            map.insert("viewport_sync".into(), Value::from(1));
        }
    }

    /// Wraps a daemon channel's receiver.
    pub fn wrap(&self, receiver: ChannelReceiver) -> ViewportReceiver {
        ViewportReceiver::new(receiver, Some(self.clone()))
    }

    /// One datagram from the host: applies it to its epoch's receiver and
    /// returns the ack to send back (None: not a diff, or no such epoch).
    pub fn on_datagram(&self, datagram: &[u8]) -> Option<Vec<u8>> {
        on_datagram(&self.inner.routes, datagram)
    }

    fn register(&self, epoch: u32, route: Route) {
        lock(&self.inner.routes).insert(epoch, route);
        self.ensure_serving();
    }

    fn unregister(&self, epoch: u32, state: &Arc<Mutex<SyncReceiver>>) {
        let mut routes = lock(&self.inner.routes);
        if routes.get(&epoch).is_some_and(|route| Arc::ptr_eq(&route.state, state)) {
            routes.remove(&epoch);
        }
    }

    /// Starts the socket task unless it runs.
    fn ensure_serving(&self) {
        let Some(net) = &self.inner.net else { return };
        let Ok(runtime) = tokio::runtime::Handle::try_current() else { return };
        let mut task = lock(&self.inner.task);
        if task.as_ref().is_some_and(|task| !task.is_finished()) {
            return;
        }
        *task = Some(runtime.spawn(serve(Weak::clone(net), Arc::clone(&self.inner.routes))));
    }
}

fn on_datagram(routes: &Routes, datagram: &[u8]) -> Option<Vec<u8>> {
    let (header, _) = sync::parse_diff_datagram(datagram)?;
    let route = lock(routes).get(&header.epoch).cloned()?;
    let ack = lock(&route.state).on_datagram(datagram);
    route.wake.notify_one();
    ack
}

async fn serve(net: Weak<WgNet>, routes: Arc<Routes>) {
    let Some(stack) = net.upgrade() else { return };
    let bound = stack.bind_datagram(PORT).await;
    drop(stack);
    let mut socket = match bound {
        Ok(socket) => socket,
        Err(error) => {
            tracing::warn!(?error, port = PORT, "viewport sync: no datagram socket");
            return;
        }
    };
    while let Some((datagram, from)) = socket.recv_from().await {
        if let Some(ack) = on_datagram(&routes, &datagram)
            && let Err(error) = socket.send_to(&ack, from, Priority::Interactive).await
        {
            tracing::debug!(?error, "viewport sync: ack not sent");
        }
    }
}

/// A daemon channel's receiver with viewport sync applied: the viewport
/// lines are swallowed and each new synced state arrives as an `output`
/// line, in order with everything else, which passes through unchanged.
pub struct ViewportReceiver {
    inner: ChannelReceiver,
    demux: Option<Demux>,
}

impl ViewportReceiver {
    /// `hub` None: a plain pass-through.
    pub fn new(receiver: ChannelReceiver, hub: Option<PhoneViewport>) -> Self {
        let demux = hub.map(|hub| Demux {
            hub,
            wake: Arc::new(Notify::new()),
            surfaces: HashMap::new(),
            grids: HashMap::new(),
            partial: Vec::new(),
            pending: VecDeque::new(),
            done: false,
        });
        Self { inner: receiver, demux }
    }

    /// The next event; `None` after `Closed` was delivered. Cancel safe.
    pub async fn recv(&mut self) -> Option<ChannelEvent> {
        let Some(demux) = self.demux.as_mut() else { return self.inner.recv().await };
        loop {
            if let Some(event) = demux.pending.pop_front() {
                return Some(event);
            }
            if demux.done {
                return None;
            }
            demux.render_due();
            if !demux.pending.is_empty() {
                continue;
            }
            let wake = Arc::clone(&demux.wake);
            let event = tokio::select! {
                event = self.inner.recv() => Some(event),
                () = wake.notified() => None,
            };
            if let Some(event) = event {
                demux.on_event(event);
            }
        }
    }
}

struct Surface {
    /// The surface id as the host sent it.
    surface: Value,
    epoch: u32,
    state: Arc<Mutex<SyncReceiver>>,
    /// The screen last rendered (None: unknown, the next one repaints all).
    prev: Option<ScreenState>,
    /// The seq last rendered.
    rendered: u64,
    /// The seq held when a stream `output` line last passed: states up to
    /// it are older than what the stream drew.
    floor: u64,
    /// The stream carries the screen (the host's path is `stream`).
    paused: bool,
}

impl Surface {
    /// The `output` line for a newer state held, if any.
    fn render_due(&mut self) -> Option<Bytes> {
        if self.paused {
            return None;
        }
        let screen = {
            let state = lock(&self.state);
            if state.seq() <= self.rendered.max(self.floor) {
                return None;
            }
            self.rendered = state.seq();
            state.screen().cloned()?
        };
        let bytes = render_screen(self.prev.as_ref(), &screen);
        self.prev = Some(screen);
        (!bytes.is_empty()).then(|| output_line(&self.surface, &bytes))
    }
}

/// What a line does.
enum Line {
    Pass,
    Swallow,
    Inject(Bytes),
}

struct Demux {
    hub: PhoneViewport,
    /// Woken by every datagram for one of this channel's surfaces.
    wake: Arc<Notify>,
    /// Synced surfaces, by their id's JSON text.
    surfaces: HashMap<String, Surface>,
    /// Each surface's grid from its last `vt-state` line.
    grids: HashMap<String, (u16, u16)>,
    /// The start of a line not yet ended.
    partial: Vec<u8>,
    pending: VecDeque<ChannelEvent>,
    /// `Closed` is queued (or was delivered).
    done: bool,
}

impl Drop for Demux {
    fn drop(&mut self) {
        for surface in self.surfaces.values() {
            self.hub.unregister(surface.epoch, &surface.state);
        }
    }
}

fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    haystack.windows(needle.len()).any(|window| window == needle)
}

fn output_line(surface: &Value, bytes: &[u8]) -> Bytes {
    let line = serde_json::json!({
        "event": "output",
        "surface": surface,
        "data": base64::engine::general_purpose::STANDARD.encode(bytes),
    });
    let mut out = serde_json::to_vec(&line).unwrap_or_default();
    out.push(b'\n');
    Bytes::from(out)
}

impl Demux {
    fn render_due(&mut self) {
        for surface in self.surfaces.values_mut() {
            if let Some(line) = surface.render_due() {
                self.pending.push_back(ChannelEvent::Data(line));
            }
        }
    }

    fn on_event(&mut self, event: Option<ChannelEvent>) {
        match event {
            Some(ChannelEvent::Data(data)) => self.on_data(data),
            Some(ChannelEvent::Closed(info)) => {
                self.flush_partial();
                self.pending.push_back(ChannelEvent::Closed(info));
                self.done = true;
            }
            None => {
                self.flush_partial();
                self.done = true;
            }
        }
    }

    fn flush_partial(&mut self) {
        if !self.partial.is_empty() {
            let partial = std::mem::take(&mut self.partial);
            self.pending.push_back(ChannelEvent::Data(Bytes::from(partial)));
        }
    }

    fn on_data(&mut self, data: Bytes) {
        if self.partial.is_empty()
            && self.surfaces.is_empty()
            && !contains(&data, b"\"viewport-")
            && !contains(&data, b"\"vt-state\"")
        {
            self.pending.push_back(ChannelEvent::Data(data));
            return;
        }
        let mut buffer = std::mem::take(&mut self.partial);
        buffer.extend_from_slice(&data);
        let mut out = Vec::new();
        let mut start = 0;
        while let Some(end) = buffer.get(start..).and_then(|rest| rest.iter().position(|&b| b == b'\n')) {
            let line = buffer.get(start..start + end + 1).unwrap_or_default();
            start += end + 1;
            match self.on_line(line) {
                Line::Pass => out.extend_from_slice(line),
                Line::Swallow => {}
                Line::Inject(injected) => {
                    if !out.is_empty() {
                        self.pending.push_back(ChannelEvent::Data(Bytes::from(std::mem::take(&mut out))));
                    }
                    self.pending.push_back(ChannelEvent::Data(injected));
                }
            }
        }
        if !out.is_empty() {
            self.pending.push_back(ChannelEvent::Data(Bytes::from(out)));
        }
        self.partial = buffer.get(start..).unwrap_or_default().to_vec();
    }

    fn on_line(&mut self, line: &[u8]) -> Line {
        let interesting = contains(line, b"\"viewport-")
            || contains(line, b"\"vt-state\"")
            || (!self.surfaces.is_empty() && contains(line, b"\"output\""));
        if !interesting {
            return Line::Pass;
        }
        let Ok(value) = serde_json::from_slice::<Value>(line) else { return Line::Pass };
        let event = value.get("event").and_then(Value::as_str).unwrap_or_default();
        let Some(surface) = value.get("surface") else { return Line::Pass };
        let key = surface.to_string();
        let number = |name: &str| value.get(name).and_then(Value::as_u64);
        match event {
            "vt-state" => {
                let grid = number("cols").zip(number("rows"));
                if let Some((cols, rows)) = grid
                    && let (Ok(cols), Ok(rows)) = (u16::try_from(cols), u16::try_from(rows))
                {
                    self.grids.insert(key, (cols, rows));
                }
                Line::Pass
            }
            "output" => {
                if let Some(synced) = self.surfaces.get_mut(&key) {
                    synced.prev = None;
                    synced.floor = lock(&synced.state).seq();
                }
                Line::Pass
            }
            "viewport-sync" => {
                if let Some(epoch) = number("epoch").and_then(|epoch| u32::try_from(epoch).ok()) {
                    self.start(key, surface.clone(), epoch);
                }
                Line::Swallow
            }
            "viewport-path" => {
                let Some(synced) = self.surfaces.get_mut(&key) else { return Line::Swallow };
                synced.paused = value.get("path").and_then(Value::as_str) != Some("datagram");
                // Whatever the stream drew, a switch to the datagrams repaints in full.
                synced.prev = None;
                synced.render_due().map_or(Line::Swallow, Line::Inject)
            }
            "viewport-history" => {
                let rows = value
                    .get("data")
                    .and_then(Value::as_str)
                    .and_then(|data| base64::engine::general_purpose::STANDARD.decode(data).ok())
                    .unwrap_or_default();
                let grid = self.grids.get(&key).copied();
                self.history(&key, surface, &rows, grid).map_or(Line::Swallow, Line::Inject)
            }
            "viewport-sync-end" => {
                if let Some(synced) = self.surfaces.remove(&key) {
                    self.hub.unregister(synced.epoch, &synced.state);
                }
                Line::Swallow
            }
            other if other.starts_with("viewport-") => Line::Swallow,
            _ => Line::Pass,
        }
    }

    fn start(&mut self, key: String, surface: Value, epoch: u32) {
        let state = Arc::new(Mutex::new(SyncReceiver::new()));
        let synced = Surface {
            surface,
            epoch,
            state: Arc::clone(&state),
            prev: None,
            rendered: 0,
            floor: 0,
            // The host's path starts on the stream.
            paused: true,
        };
        if let Some(old) = self.surfaces.insert(key, synced) {
            self.hub.unregister(old.epoch, &old.state);
        }
        self.hub.register(epoch, Route { state, wake: Arc::clone(&self.wake) });
    }

    /// The `output` line that pushes `rows` into the scrollback and repaints
    /// the newest screen known (just the rows without one, on `grid`).
    fn history(
        &mut self,
        key: &str,
        surface: &Value,
        rows: &[u8],
        grid: Option<(u16, u16)>,
    ) -> Option<Bytes> {
        let Some(synced) = self.surfaces.get_mut(key) else {
            let (cols, height) = grid?;
            return Some(output_line(surface, &push_history(rows, cols, height)));
        };
        let (held, seq) = {
            let state = lock(&synced.state);
            if !synced.paused && state.seq() > synced.rendered.max(synced.floor) {
                (state.screen().cloned(), state.seq())
            } else {
                (None, 0)
            }
        };
        match held.or_else(|| synced.prev.clone()) {
            Some(screen) => {
                let bytes = render_history(rows, &screen);
                synced.prev = Some(screen);
                synced.rendered = synced.rendered.max(seq);
                Some(output_line(surface, &bytes))
            }
            None => {
                let (cols, height) = grid?;
                synced.prev = None;
                Some(output_line(surface, &push_history(rows, cols, height)))
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use base64::Engine as _;
    use cmux_terminal_projection::sync::{HistoryTracker, SyncSender};

    use super::*;
    use crate::{Link, LinkConfig, Role};

    fn feed(term: &mut Terminal, bytes: &[u8]) {
        for &byte in bytes {
            term.advance(byte);
        }
    }

    fn shown(cols: usize, rows: usize, bytes: &[u8]) -> (Terminal, ScreenState) {
        let mut term = Terminal::new(cols, rows, 100);
        feed(&mut term, bytes);
        let state = ScreenState::capture(&term);
        (term, state)
    }

    /// A fresh terminal fed `render_screen(None, ..)` shows the host's screen.
    fn assert_repaints(cols: usize, rows: usize, host: &[u8]) {
        let (_, next) = shown(cols, rows, host);
        let mut phone = Terminal::new(cols, rows, 100);
        // Something else on the phone first: the repaint owes it nothing.
        feed(&mut phone, b"\x1b[41mjunk\x1b[0m\r\n\xe4\xb8\xad\xe6\x96\x87 \x1b[?2004h\x1b[5 q");
        feed(&mut phone, &render_screen(None, &next));
        assert_eq!(ScreenState::capture(&phone), next, "repaint of {host:?}");
        assert!(phone.history.is_empty(), "a repaint keeps out of the scrollback");
    }

    /// A terminal showing `before` fed `render_screen(Some(before), after)` shows `after`.
    fn assert_diffs(cols: usize, rows: usize, before: &[u8], after: &[u8]) {
        let (_, prev) = shown(cols, rows, before);
        let (_, next) = shown(cols, rows, &[before, after].concat());
        // The phone drew `prev` from the program's bytes, or from a repaint.
        let mut phone = Terminal::new(cols, rows, 100);
        feed(&mut phone, before);
        feed(&mut phone, &render_screen(Some(&prev), &next));
        assert_eq!(ScreenState::capture(&phone), next, "diff {before:?} -> {after:?}");
        let mut phone = Terminal::new(cols, rows, 100);
        feed(&mut phone, &render_screen(None, &prev));
        feed(&mut phone, &render_screen(Some(&prev), &next));
        assert_eq!(ScreenState::capture(&phone), next, "diff after a repaint {before:?} -> {after:?}");
    }

    #[test]
    fn a_repaint_shows_the_screen() {
        // Styles, an erase in a background, a link.
        assert_repaints(
            20,
            4,
            b"\x1b[1;31mred\x1b[0m \x1b[3;4:3;58;2;1;2;3mcurl\x1b[0m\r\n\x1b[48;5;21mbg\x1b[K\x1b[0m\r\n\
              \x1b]8;id=1;https://example.com\x1b\\link\x1b]8;;\x1b\\ \x1b[7mrev",
        );
        // Wide glyphs, one wrapping from the last column of a middle row and of the last row.
        assert_repaints(9, 3, "ab\u{4e2d}\u{6587}x\r\n12345678\u{4e2d}\u{6587}".as_bytes());
        assert_repaints(9, 3, "\x1b[3;1H12345678\u{4e2d}".as_bytes());
        assert_repaints(9, 3, "\x1b[1;2r\x1b[3;1H12345678\u{4e2d}\x1b[r".as_bytes());
        assert_repaints(9, 3, "\x1b[44m\x1b[1;2r\x1b[3;1H12345678\u{4e2d}\x1b[r\x1b[0m".as_bytes());
        // A wide glyph's other half overwritten: a blank in its full style.
        assert_repaints(10, 2, "\x1b[31;1m\u{4e2d}\u{6587}\x1b[0m\x1b[1;2Hx\x1b[1;3Hy".as_bytes());
        // Clusters, combining marks.
        assert_repaints(10, 2, "e\u{301}\u{1f44d}\u{1f3fd}\u{2764}\u{fe0f}!".as_bytes());
        // The cursor: hidden, a shape, a place.
        assert_repaints(10, 3, b"abc\x1b[?25l\x1b[5 q\x1b[2;7H");
        // Modes.
        assert_repaints(10, 2, b"\x1b[?1h\x1b=\x1b[?2004h\x1b[?1000h\x1b[?1006h\x1b[=5u\x1b[?12h\x1b[?2027l");
        // The alternate screen.
        assert_repaints(10, 3, b"primary\x1b[?1049h\x1b[2;3Halt\x1b[?1004h");
        // A blank screen.
        assert_repaints(5, 2, b"");
    }

    #[test]
    fn a_diff_from_the_previous_screen_shows_the_next() {
        assert_diffs(12, 3, b"hello\r\nworld", b"\x1b[1;3HLL\x1b[33m!\x1b[0m");
        assert_diffs(12, 3, b"hello\r\nworld", "\x1b[2;2H\u{4e2d}".as_bytes());
        assert_diffs(12, 3, "ab\u{4e2d}cd".as_bytes(), b"\x1b[1;4Hx");
        assert_diffs(9, 3, b"one\r\ntwo", "\x1b[1;1H12345678\u{4e2d}".as_bytes());
        assert_diffs(9, 3, b"one", "\x1b[3;1H12345678\u{4e2d}".as_bytes());
        assert_diffs(9, 3, b"one", "\x1b[1;2r\x1b[3;1H12345678\u{4e2d}\x1b[r".as_bytes());
        assert_diffs(12, 3, b"shell $ ", b"\x1b[?1049h\x1b[Hvim\x1b[?1h\x1b=");
        assert_diffs(12, 3, b"\x1b[?1049h\x1b[Hvim", b"\x1b[?1049l");
        assert_diffs(12, 3, b"a\r\nb\r\nc", b"\r\nd\r\ne");
        assert_diffs(12, 3, b"x\x1b[?2004h", b"\x1b[?2004l\x1b[?25l\x1b[2 q\x1b[=1u");
        assert_diffs(12, 3, b"x\x1b[42m\x1b[K", b"\x1b[0m\x1b[1;5H\x1b[44m\x1b[2X");
    }

    #[test]
    fn the_same_screen_renders_nothing() {
        let (_, state) = shown(8, 2, b"same");
        assert!(render_screen(Some(&state), &state).is_empty());
    }

    #[test]
    fn history_goes_to_the_scrollback_and_the_screen_is_repainted() {
        let (cols, rows) = (10, 3);
        let mut host = Terminal::new(cols, rows, 100);
        let mut tracker = HistoryTracker::new();
        let mut phone = Terminal::new(cols, rows, 100);
        feed(&mut host, b"1\r\n2\r\n3");
        feed(&mut phone, b"1\r\n2\r\n3");
        assert!(tracker.take_new_rows(&host).is_empty());
        // Two rows scroll off, then five more (more than the screen holds).
        for more in [&b"\r\n4\r\n5"[..], b"\r\n6\r\n7\r\n8\r\n9\r\n10"] {
            feed(&mut host, more);
            let new_rows = tracker.take_new_rows(&host);
            assert!(!new_rows.is_empty());
            let screen = ScreenState::capture(&host);
            feed(&mut phone, &render_history(&new_rows, &screen));
            assert_eq!(phone.history, host.history);
            assert_eq!(ScreenState::capture(&phone), screen);
        }
        // A cleared scrollback starts over.
        feed(&mut host, b"\x1b[3J\r\n11");
        let new_rows = tracker.take_new_rows(&host);
        let screen = ScreenState::capture(&host);
        feed(&mut phone, &render_history(&new_rows, &screen));
        assert_eq!(phone.history, host.history);
        assert_eq!(ScreenState::capture(&phone), screen);
    }

    #[test]
    fn rows_alone_go_to_the_scrollback() {
        let mut host = Terminal::new(10, 3, 100);
        feed(&mut host, b"1\r\n2\r\n3\r\n4");
        let rows = HistoryTracker::new().take_new_rows(&host);
        let mut phone = Terminal::new(10, 3, 100);
        feed(&mut phone, &push_history(&rows, 10, 3));
        assert_eq!(phone.history, host.history);
        assert_eq!(ScreenState::capture(&phone), ScreenState::blank(10, 3));
    }

    fn pair() -> (Link, Link) {
        let (a, b) = tokio::io::duplex(1 << 20);
        (
            Link::new(a, Role::Phone, LinkConfig::default(), None),
            Link::new(b, Role::Mac, LinkConfig::default(), None),
        )
    }

    async fn next_data(receiver: &mut ViewportReceiver) -> Vec<u8> {
        let event = tokio::time::timeout(std::time::Duration::from_secs(5), receiver.recv()).await;
        match event.expect("an event in time") {
            Some(ChannelEvent::Data(bytes)) => bytes.to_vec(),
            other => panic!("unexpected {other:?}"),
        }
    }

    fn output_data(line: &[u8]) -> Vec<u8> {
        let value: Value = serde_json::from_slice(line).expect("json");
        assert_eq!(value["event"], "output");
        assert_eq!(value["surface"], 7);
        assert!(line.ends_with(b"\n"));
        base64::engine::general_purpose::STANDARD.decode(value["data"].as_str().unwrap()).unwrap()
    }

    #[test]
    fn daemon_args_ask_for_pseq_and_only_with_an_overlay_for_sync() {
        let hub = PhoneViewport::new(None, true);
        assert!(!hub.requests_sync());
        let mut args = serde_json::json!({ "session": "s" });
        hub.merge_daemon_args(&mut args);
        assert_eq!(args, serde_json::json!({ "session": "s", "pseq": true }));
    }

    #[tokio::test]
    async fn the_wrapper_swallows_viewport_lines_and_injects_synced_screens() {
        let (phone, mac) = pair();
        let host = tokio::spawn(async move {
            let incoming = mac.accept().await.expect("incoming");
            (mac, incoming.channel)
        });
        let channel = phone.open("daemon", serde_json::json!({})).await.unwrap();
        let (mac, mac_channel) = host.await.unwrap();
        let hub = PhoneViewport::new(None, true);
        let (_sender, receiver) = channel.split();
        let mut receiver = hub.wrap(receiver);
        let send = |line: String| {
            let bytes = Bytes::from(format!("{line}\n"));
            let channel = &mac_channel;
            async move { channel.send(bytes).await.unwrap() }
        };

        // Lines that are not viewport lines pass unchanged, partial lines too.
        send(r#"{"event":"hello","surface":7}"#.into()).await;
        assert_eq!(next_data(&mut receiver).await, b"{\"event\":\"hello\",\"surface\":7}\n");
        mac_channel.send(Bytes::from_static(b"{\"event\":\"vt-state\",\"surface\":7,")).await.unwrap();
        mac_channel.send(Bytes::from_static(b"\"data\":\"\",\"cols\":10,\"rows\":3}\nraw")).await.unwrap();
        assert_eq!(
            next_data(&mut receiver).await,
            b"{\"event\":\"vt-state\",\"surface\":7,\"data\":\"\",\"cols\":10,\"rows\":3}\n"
        );

        // `raw` was the start of the marker's line.
        send(r#"{"event":"marker"}"#.into()).await;
        assert_eq!(next_data(&mut receiver).await, b"raw{\"event\":\"marker\"}\n");

        // The host's screen, as the host's sync sender has it.
        let (_, screen) = shown(10, 3, "synced \u{4e2d}\r\n\x1b[32mgreen".as_bytes());
        let mut sender = SyncSender::new(1200);
        sender.update(screen.clone());
        send(format!(r#"{{"event":"viewport-sync","surface":7,"epoch":{}}}"#, sender.epoch())).await;
        send(r#"{"event":"marker2"}"#.into()).await;
        assert_eq!(next_data(&mut receiver).await, b"{\"event\":\"marker2\"}\n");
        for datagram in sender.datagrams() {
            if let Some(ack) = hub.on_datagram(&datagram) {
                sender.on_ack(&ack);
            }
        }
        assert_eq!(sender.acked_seq(), 1);
        // On the stream path nothing is rendered; the switch renders the held screen.
        send(r#"{"event":"viewport-path","surface":7,"path":"datagram"}"#.into()).await;
        let mut phone_term = Terminal::new(10, 3, 100);
        feed(&mut phone_term, &output_data(&next_data(&mut receiver).await));
        assert_eq!(ScreenState::capture(&phone_term), screen);

        // A datagram while the receiver waits wakes it.
        let (_, screen2) = shown(10, 3, "synced \u{4e2d}\r\n\x1b[32mgreen\x1b[0m!".as_bytes());
        sender.update(screen2.clone());
        let datagrams = sender.datagrams();
        let feeder = {
            let hub = hub.clone();
            tokio::spawn(async move {
                tokio::time::sleep(std::time::Duration::from_millis(20)).await;
                datagrams.iter().fold(None, |last, d| hub.on_datagram(d).or(last))
            })
        };
        let line = next_data(&mut receiver).await;
        sender.on_ack(&feeder.await.unwrap().expect("an ack"));
        assert_eq!(sender.acked_seq(), 2);
        let diff = output_data(&line);
        assert!(diff.len() < 64, "a diff, not a repaint: {diff:?}");
        feed(&mut phone_term, &diff);
        assert_eq!(ScreenState::capture(&phone_term), screen2);

        // History rows, then the screen repainted.
        let mut rows = Vec::new();
        rows.extend_from_slice(b"old\r\n");
        let data = base64::engine::general_purpose::STANDARD.encode(&rows);
        send(format!(r#"{{"event":"viewport-history","surface":7,"data":"{data}"}}"#)).await;
        feed(&mut phone_term, &output_data(&next_data(&mut receiver).await));
        assert_eq!(phone_term.history.len(), 1);
        assert_eq!(ScreenState::capture(&phone_term), screen2);

        // The end: unregistered, swallowed.
        send(r#"{"event":"viewport-sync-end","surface":7}"#.into()).await;
        send(r#"{"event":"after"}"#.into()).await;
        assert_eq!(next_data(&mut receiver).await, b"{\"event\":\"after\"}\n");
        sender.update(ScreenState::blank(10, 3));
        assert!(sender.datagrams().iter().all(|d| hub.on_datagram(d).is_none()));

        mac_channel.close("done", "").await;
        match receiver.recv().await {
            Some(ChannelEvent::Closed(info)) => assert_eq!(info.code, "done"),
            other => panic!("unexpected {other:?}"),
        }
        assert!(receiver.recv().await.is_none());
        drop(mac);
    }

    #[tokio::test]
    async fn without_a_hub_everything_passes() {
        let (phone, mac) = pair();
        let host = tokio::spawn(async move {
            let incoming = mac.accept().await.expect("incoming");
            (mac, incoming.channel)
        });
        let channel = phone.open("daemon", serde_json::json!({})).await.unwrap();
        let (_mac, mac_channel) = host.await.unwrap();
        let (_sender, receiver) = channel.split();
        let mut receiver = ViewportReceiver::new(receiver, None);
        let line = b"{\"event\":\"viewport-sync\",\"surface\":1,\"epoch\":5}\n";
        mac_channel.send(Bytes::from_static(line)).await.unwrap();
        assert_eq!(next_data(&mut receiver).await, line);
    }
}
