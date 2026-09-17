//! Optional Ratatui wrapper for a cmux [`SidebarView`].
//!
//! This crate owns a typed attachment stream on a worker thread, moves updates
//! through a bounded queue, renders the latest frame, and forwards Crossterm
//! input through the resource API. Dropping [`SidebarRuntime`] cancels only its
//! stream lease; it never deletes or disables the sidebar view.

use cmux::{
    ColorHex, Document, Error, RenderCursor, RenderPatch, RenderRow, RenderRun, RenderScroll,
    RenderSnapshot, Result, SidebarInputOptions, SidebarView, SidebarViewItem, SidebarViewStream,
    Size, StreamEnd,
};
use crossterm::event::{
    Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers, MediaKeyCode, ModifierKeyCode,
    MouseButton, MouseEvent, MouseEventKind,
};
use ratatui::buffer::Buffer;
use ratatui::layout::Rect;
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Paragraph, Widget, Wrap};
use serde_json::{Value, json};
use std::sync::mpsc::{self, Receiver, SyncSender, TryRecvError, TrySendError};
use std::thread::{self, JoinHandle};

/// Runtime limits and initial rendering state.
#[derive(Clone, Debug)]
pub struct SidebarConfig {
    pub queue_capacity: usize,
    pub initial_columns: Option<u16>,
    pub initial_rows: Option<u16>,
    pub fallback_title: String,
}

impl Default for SidebarConfig {
    fn default() -> Self {
        Self {
            queue_capacity: 64,
            initial_columns: None,
            initial_rows: None,
            fallback_title: "cmux".to_string(),
        }
    }
}

/// Latest renderable sidebar state.
#[derive(Clone, Debug, PartialEq)]
pub struct SidebarModel {
    pub title: String,
    pub size: Option<Size>,
    pub cursor: Option<RenderCursor>,
    pub default_fg: Option<ColorHex>,
    pub default_bg: Option<ColorHex>,
    pub scrollback_rows: u32,
    pub rows: Vec<RenderRow>,
    pub scroll: Option<RenderScroll>,
    pub status: Option<String>,
    pub error: Option<String>,
    pub unknown_events: u64,
    pub last_unknown: Option<UnknownSidebarEvent>,
}

/// Preserved payload for a future sidebar event unknown to this SDK version.
#[derive(Clone, Debug, PartialEq)]
pub struct UnknownSidebarEvent {
    pub kind: String,
    pub raw: Document,
}

impl SidebarModel {
    pub fn new(title: impl Into<String>) -> Self {
        Self {
            title: title.into(),
            size: None,
            cursor: None,
            default_fg: None,
            default_bg: None,
            scrollback_rows: 0,
            rows: Vec::new(),
            scroll: None,
            status: None,
            error: None,
            unknown_events: 0,
            last_unknown: None,
        }
    }

    /// Reconciles one typed attachment item into the latest renderable frame.
    ///
    /// Applications that own stream recovery can use this reducer without
    /// using [`SidebarRuntime`].
    pub fn apply_item(&mut self, item: SidebarViewItem) {
        match item {
            SidebarViewItem::Snapshot { render, .. } => {
                self.apply_snapshot(render);
                self.error = None;
            }
            SidebarViewItem::Patch { render, .. } => {
                self.apply_patch(render);
                self.error = None;
            }
            SidebarViewItem::Scroll { scroll, .. } => {
                self.scroll = Some(scroll);
            }
            SidebarViewItem::Unknown { kind, raw } => {
                self.status = Some(format!("unknown event: {kind}"));
                self.unknown_events += 1;
                self.last_unknown = Some(UnknownSidebarEvent { kind, raw });
            }
        }
    }

    fn apply_snapshot(&mut self, snapshot: RenderSnapshot) {
        self.size = Some(snapshot.size);
        self.cursor = Some(snapshot.cursor);
        self.default_fg = Some(snapshot.default_fg);
        self.default_bg = Some(snapshot.default_bg);
        self.scrollback_rows = snapshot.scrollback_rows;
        self.rows = snapshot.rows;
    }

    fn apply_patch(&mut self, patch: RenderPatch) {
        self.cursor = Some(patch.cursor);
        if let Some(size) = patch.size {
            self.size = Some(size);
        }
        if let Some(default_fg) = patch.default_fg {
            self.default_fg = Some(default_fg);
        }
        if let Some(default_bg) = patch.default_bg {
            self.default_bg = Some(default_bg);
        }
        if let Some(scrollback_rows) = patch.scrollback_rows {
            self.scrollback_rows = scrollback_rows;
        }
        if patch.full_reset {
            self.rows = patch.rows;
        } else {
            for row in patch.rows {
                match self.rows.iter().position(|current| current.row == row.row) {
                    Some(index) => self.rows[index] = row,
                    None => self.rows.push(row),
                }
            }
            self.rows.sort_by_key(|row| row.row);
        }
    }
}

enum WorkerUpdate {
    Item(Box<SidebarViewItem>),
}

enum WorkerLifecycle {
    Failed(String),
    Ended(StreamEnd),
    QueueOverflow,
}

/// Typed state for the current attachment lease.
#[derive(Clone, Debug, PartialEq)]
pub enum SidebarRuntimeState {
    Attached,
    Ended(StreamEnd),
    QueueOverflow,
    Failed(String),
}

/// Live sidebar stream, input forwarder, and Ratatui model.
pub struct SidebarRuntime {
    view: SidebarView,
    receiver: Receiver<WorkerUpdate>,
    lifecycle: Receiver<WorkerLifecycle>,
    model: SidebarModel,
    cancellation: cmux::StreamCancellation,
    state: SidebarRuntimeState,
    queue_capacity: usize,
    worker: Option<JoinHandle<()>>,
}

impl SidebarRuntime {
    pub fn start(view: SidebarView, config: SidebarConfig) -> Result<Self> {
        if config.queue_capacity == 0 {
            return Err(Error::InvalidArgument(
                "sidebar queue_capacity must be greater than zero".to_string(),
            ));
        }
        if config.initial_columns.is_some() != config.initial_rows.is_some() {
            return Err(Error::InvalidArgument(
                "initial_columns and initial_rows must be set together".to_string(),
            ));
        }
        if let Some((columns, rows)) = config.initial_columns.zip(config.initial_rows) {
            view.resize(Size::new(columns, rows)?)?;
        }
        let (receiver, lifecycle, cancellation, worker) =
            spawn_stream_worker(&view, config.queue_capacity)?;
        Ok(Self {
            view,
            receiver,
            lifecycle,
            model: SidebarModel::new(config.fallback_title),
            cancellation,
            state: SidebarRuntimeState::Attached,
            queue_capacity: config.queue_capacity,
            worker: Some(worker),
        })
    }

    pub fn view(&self) -> &SidebarView {
        &self.view
    }

    pub fn model(&self) -> &SidebarModel {
        &self.model
    }

    pub fn state(&self) -> &SidebarRuntimeState {
        &self.state
    }

    /// Drains currently queued updates without blocking.
    pub fn poll_updates(&mut self) -> usize {
        let mut applied = 0;
        while let Ok(WorkerUpdate::Item(item)) = self.receiver.try_recv() {
            self.model.apply_item(*item);
            applied += 1;
        }
        loop {
            match self.lifecycle.try_recv() {
                Ok(WorkerLifecycle::Ended(end)) => {
                    self.model.status = Some(format!("ended: {:?}", end.reason).to_lowercase());
                    self.model.error = end.error.as_ref().map(|error| error.message.clone());
                    self.state = SidebarRuntimeState::Ended(end);
                    applied += 1;
                }
                Ok(WorkerLifecycle::Failed(error)) => {
                    self.model.error = Some(error.clone());
                    self.state = SidebarRuntimeState::Failed(error);
                    applied += 1;
                }
                Ok(WorkerLifecycle::QueueOverflow) => {
                    self.model.error = Some(
                        "sidebar update queue overflowed; reopen the attachment to recover"
                            .to_string(),
                    );
                    self.state = SidebarRuntimeState::QueueOverflow;
                    applied += 1;
                }
                Err(TryRecvError::Empty | TryRecvError::Disconnected) => break,
            }
        }
        applied
    }

    pub fn widget(&self) -> SidebarWidget<'_> {
        SidebarWidget::new(&self.model)
    }

    pub fn resize(&self, columns: u16, rows: u16) -> Result<()> {
        self.view.resize(Size::new(columns, rows)?).map(|_| ())
    }

    /// Forwards one Crossterm event. Returns `false` for unsupported events.
    pub fn handle_event(&self, event: &Event) -> Result<bool> {
        match event {
            Event::Resize(columns, rows) => {
                self.resize(*columns, *rows)?;
                Ok(true)
            }
            _ => {
                let Some(value) = encode_event(event) else {
                    return Ok(false);
                };
                let data =
                    serde_json::to_vec(&value).map_err(|error| Error::Decode(error.to_string()))?;
                self.view.input(SidebarInputOptions { data }).map(|_| true)
            }
        }
    }

    /// Opens a fresh attachment after a terminal end or local queue overflow.
    ///
    /// The latest frame is retained until the new stream supplies a snapshot.
    pub fn reattach(&mut self) -> Result<()> {
        if matches!(self.state, SidebarRuntimeState::Attached) {
            return Err(Error::InvalidArgument("sidebar attachment is still active".to_string()));
        }
        if let Some(worker) = self.worker.take() {
            worker.join().map_err(|_| Error::Connection("sidebar worker panicked".to_string()))?;
        }
        let (receiver, lifecycle, cancellation, worker) =
            spawn_stream_worker(&self.view, self.queue_capacity)?;
        self.receiver = receiver;
        self.lifecycle = lifecycle;
        self.cancellation = cancellation;
        self.worker = Some(worker);
        self.state = SidebarRuntimeState::Attached;
        self.model.status = None;
        self.model.error = None;
        Ok(())
    }

    /// Cancels the attachment and waits for the worker to stop.
    pub fn shutdown(mut self) -> Result<()> {
        if matches!(self.state, SidebarRuntimeState::Attached) {
            self.cancellation.cancel()?;
        }
        if let Some(worker) = self.worker.take() {
            worker.join().map_err(|_| Error::Connection("sidebar worker panicked".to_string()))?;
        }
        self.poll_updates();
        Ok(())
    }
}

impl Drop for SidebarRuntime {
    fn drop(&mut self) {
        if matches!(self.state, SidebarRuntimeState::Attached) {
            let _ = self.cancellation.cancel();
        }
        // A blocking join in Drop could stall terminal teardown if a peer is
        // unresponsive. Dropping JoinHandle detaches the already-canceled
        // worker; explicit shutdown waits and reports errors.
        self.worker.take();
    }
}

type SpawnedWorker =
    (Receiver<WorkerUpdate>, Receiver<WorkerLifecycle>, cmux::StreamCancellation, JoinHandle<()>);

fn spawn_stream_worker(view: &SidebarView, queue_capacity: usize) -> Result<SpawnedWorker> {
    let stream = view.attach()?;
    let cancellation = stream.cancellation();
    let (sender, receiver) = mpsc::sync_channel(queue_capacity);
    let (lifecycle_sender, lifecycle) = mpsc::channel();
    let worker = thread::Builder::new()
        .name("cmux-sidebar-stream".to_string())
        .spawn(move || stream_worker(stream, sender, lifecycle_sender))
        .map_err(|error| Error::Connection(format!("cannot start sidebar worker: {error}")))?;
    Ok((receiver, lifecycle, cancellation, worker))
}

fn stream_worker(
    mut stream: SidebarViewStream,
    sender: SyncSender<WorkerUpdate>,
    lifecycle: mpsc::Sender<WorkerLifecycle>,
) {
    loop {
        let update = match stream.recv() {
            Ok(Some(item)) => WorkerUpdate::Item(Box::new(item.value)),
            Ok(None) => {
                let event = stream.end().cloned().map_or_else(
                    || {
                        WorkerLifecycle::Failed(
                            "sidebar attachment ended without stream_end metadata".to_string(),
                        )
                    },
                    WorkerLifecycle::Ended,
                );
                let _ = lifecycle.send(event);
                return;
            }
            Err(error) => {
                let event = stream.end().cloned().map_or_else(
                    || WorkerLifecycle::Failed(error.to_string()),
                    WorkerLifecycle::Ended,
                );
                let _ = lifecycle.send(event);
                return;
            }
        };
        match sender.try_send(update) {
            Ok(()) => {}
            Err(TrySendError::Full(_)) => {
                match stream.cancel() {
                    Ok(()) => {
                        let _ = lifecycle.send(WorkerLifecycle::QueueOverflow);
                    }
                    Err(error) => {
                        let _ = lifecycle.send(WorkerLifecycle::Failed(error.to_string()));
                    }
                }
                return;
            }
            Err(TrySendError::Disconnected(_)) => {
                let _ = stream.cancel();
                return;
            }
        }
    }
}

/// Borrowed Ratatui widget for the latest [`SidebarModel`].
pub struct SidebarWidget<'a> {
    model: &'a SidebarModel,
    block: Option<Block<'a>>,
    footer: Vec<Line<'a>>,
}

impl<'a> SidebarWidget<'a> {
    pub fn new(model: &'a SidebarModel) -> Self {
        Self {
            model,
            block: Some(Block::default().borders(Borders::ALL).title(model.title.clone())),
            footer: Vec::new(),
        }
    }

    /// Replaces the default titled border with an application-owned block.
    pub fn block(mut self, block: Block<'a>) -> Self {
        self.block = Some(block);
        self
    }

    /// Renders only the sidebar contents for composition inside an outer widget.
    pub fn without_block(mut self) -> Self {
        self.block = None;
        self
    }

    /// Appends an application-owned status or control line after cmux content.
    pub fn footer(mut self, line: impl Into<Line<'a>>) -> Self {
        self.footer.push(line.into());
        self
    }
}

impl Widget for SidebarWidget<'_> {
    fn render(self, area: Rect, buffer: &mut Buffer) {
        let row_count =
            self.model.size.map_or_else(|| self.model.rows.len(), |size| usize::from(size.rows));
        let mut lines = (0..row_count)
            .map(|row| {
                self.model
                    .rows
                    .iter()
                    .find(|candidate| usize::from(candidate.row) == row)
                    .map_or_else(|| Line::from(""), |row| render_row(row, self.model))
            })
            .collect::<Vec<_>>();
        if let Some(status) = &self.model.status {
            lines.push(Line::from(Span::styled(
                status.clone(),
                Style::default().fg(Color::DarkGray),
            )));
        }
        if let Some(error) = &self.model.error {
            lines.push(Line::from(Span::styled(error.clone(), Style::default().fg(Color::Red))));
        }
        lines.extend(self.footer);
        let paragraph = Paragraph::new(lines).wrap(Wrap { trim: false });
        match self.block {
            Some(block) => paragraph.block(block).render(area, buffer),
            None => paragraph.render(area, buffer),
        }
    }
}

fn render_row(row: &RenderRow, model: &SidebarModel) -> Line<'static> {
    Line::from(
        row.runs
            .iter()
            .map(|run| Span::styled(run.text.clone(), render_style(run, model)))
            .collect::<Vec<_>>(),
    )
}

fn render_style(run: &RenderRun, model: &SidebarModel) -> Style {
    let mut style = Style::default();
    if let Some(color) = run.fg.as_ref().or(model.default_fg.as_ref()) {
        style = style.fg(ratatui_color(color));
    }
    if let Some(color) = run.bg.as_ref().or(model.default_bg.as_ref()) {
        style = style.bg(ratatui_color(color));
    }
    let mut modifiers = Modifier::empty();
    for (attribute, modifier) in [
        (RenderRun::ATTR_BOLD, Modifier::BOLD),
        (RenderRun::ATTR_ITALIC, Modifier::ITALIC),
        (RenderRun::ATTR_STRIKETHROUGH, Modifier::CROSSED_OUT),
        (RenderRun::ATTR_INVERSE, Modifier::REVERSED),
        (RenderRun::ATTR_FAINT, Modifier::DIM),
        (RenderRun::ATTR_INVISIBLE, Modifier::HIDDEN),
        (RenderRun::ATTR_BLINK, Modifier::SLOW_BLINK),
    ] {
        if run.has_attr(attribute) {
            modifiers |= modifier;
        }
    }
    if run.underline.is_some() {
        modifiers |= Modifier::UNDERLINED;
    }
    style.add_modifier(modifiers)
}

fn ratatui_color(color: &ColorHex) -> Color {
    let value = color.as_str();
    let parse = |range: std::ops::Range<usize>| {
        u8::from_str_radix(&value[range], 16).expect("validated color hex")
    };
    Color::Rgb(parse(1..3), parse(3..5), parse(5..7))
}

/// Converts supported Crossterm events to stable sidebar input records.
#[allow(unreachable_patterns)]
pub fn encode_event(event: &Event) -> Option<Value> {
    match event {
        Event::Key(key) => Some(encode_key(*key)),
        Event::Mouse(mouse) => Some(encode_mouse(*mouse)),
        Event::Paste(text) => Some(json!({"kind": "paste", "text": text})),
        Event::FocusGained => Some(json!({"kind": "focus", "focused": true})),
        Event::FocusLost => Some(json!({"kind": "focus", "focused": false})),
        Event::Resize(_, _) => None,
        // cmux's application workspace carries a private Crossterm extension.
        // Public consumers use upstream Crossterm, so unknown future variants
        // remain unsupported instead of entering this crate's API.
        _ => None,
    }
}

fn encode_key(key: KeyEvent) -> Value {
    json!({
        "kind": "key",
        "code": key_code(key.code),
        "modifiers": modifiers(key.modifiers),
        "event": match key.kind {
            KeyEventKind::Press => "press",
            KeyEventKind::Repeat => "repeat",
            KeyEventKind::Release => "release",
        }
    })
}

fn key_code(code: KeyCode) -> String {
    match code {
        KeyCode::Backspace => "backspace".to_string(),
        KeyCode::Enter => "enter".to_string(),
        KeyCode::Left => "left".to_string(),
        KeyCode::Right => "right".to_string(),
        KeyCode::Up => "up".to_string(),
        KeyCode::Down => "down".to_string(),
        KeyCode::Home => "home".to_string(),
        KeyCode::End => "end".to_string(),
        KeyCode::PageUp => "page_up".to_string(),
        KeyCode::PageDown => "page_down".to_string(),
        KeyCode::Tab => "tab".to_string(),
        KeyCode::BackTab => "back_tab".to_string(),
        KeyCode::Delete => "delete".to_string(),
        KeyCode::Insert => "insert".to_string(),
        KeyCode::F(number) => format!("f{number}"),
        KeyCode::Char(character) => character.to_string(),
        KeyCode::Null => "null".to_string(),
        KeyCode::Esc => "escape".to_string(),
        KeyCode::CapsLock => "caps_lock".to_string(),
        KeyCode::ScrollLock => "scroll_lock".to_string(),
        KeyCode::NumLock => "num_lock".to_string(),
        KeyCode::PrintScreen => "print_screen".to_string(),
        KeyCode::Pause => "pause".to_string(),
        KeyCode::Menu => "menu".to_string(),
        KeyCode::KeypadBegin => "keypad_begin".to_string(),
        KeyCode::Media(media) => media_key(media).to_string(),
        KeyCode::Modifier(modifier) => modifier_key(modifier).to_string(),
    }
}

fn media_key(key: MediaKeyCode) -> &'static str {
    match key {
        MediaKeyCode::Play => "media_play",
        MediaKeyCode::Pause => "media_pause",
        MediaKeyCode::PlayPause => "media_play_pause",
        MediaKeyCode::Reverse => "media_reverse",
        MediaKeyCode::Stop => "media_stop",
        MediaKeyCode::FastForward => "media_fast_forward",
        MediaKeyCode::Rewind => "media_rewind",
        MediaKeyCode::TrackNext => "media_track_next",
        MediaKeyCode::TrackPrevious => "media_track_previous",
        MediaKeyCode::Record => "media_record",
        MediaKeyCode::LowerVolume => "media_volume_down",
        MediaKeyCode::RaiseVolume => "media_volume_up",
        MediaKeyCode::MuteVolume => "media_mute",
    }
}

fn modifier_key(key: ModifierKeyCode) -> &'static str {
    match key {
        ModifierKeyCode::LeftShift => "left_shift",
        ModifierKeyCode::LeftControl => "left_control",
        ModifierKeyCode::LeftAlt => "left_alt",
        ModifierKeyCode::LeftSuper => "left_super",
        ModifierKeyCode::LeftHyper => "left_hyper",
        ModifierKeyCode::LeftMeta => "left_meta",
        ModifierKeyCode::RightShift => "right_shift",
        ModifierKeyCode::RightControl => "right_control",
        ModifierKeyCode::RightAlt => "right_alt",
        ModifierKeyCode::RightSuper => "right_super",
        ModifierKeyCode::RightHyper => "right_hyper",
        ModifierKeyCode::RightMeta => "right_meta",
        ModifierKeyCode::IsoLevel3Shift => "iso_level3_shift",
        ModifierKeyCode::IsoLevel5Shift => "iso_level5_shift",
    }
}

fn modifiers(modifiers: KeyModifiers) -> Vec<&'static str> {
    [
        (KeyModifiers::SHIFT, "shift"),
        (KeyModifiers::CONTROL, "control"),
        (KeyModifiers::ALT, "alt"),
        (KeyModifiers::SUPER, "super"),
        (KeyModifiers::HYPER, "hyper"),
        (KeyModifiers::META, "meta"),
    ]
    .into_iter()
    .filter_map(|(flag, name)| modifiers.contains(flag).then_some(name))
    .collect()
}

fn encode_mouse(mouse: MouseEvent) -> Value {
    let (action, button) = match mouse.kind {
        MouseEventKind::Down(button) => ("down", Some(mouse_button(button))),
        MouseEventKind::Up(button) => ("up", Some(mouse_button(button))),
        MouseEventKind::Drag(button) => ("drag", Some(mouse_button(button))),
        MouseEventKind::Moved => ("move", None),
        MouseEventKind::ScrollDown => ("scroll_down", None),
        MouseEventKind::ScrollUp => ("scroll_up", None),
        MouseEventKind::ScrollLeft => ("scroll_left", None),
        MouseEventKind::ScrollRight => ("scroll_right", None),
    };
    json!({
        "kind": "mouse",
        "action": action,
        "button": button,
        "column": mouse.column,
        "row": mouse.row,
        "modifiers": modifiers(mouse.modifiers),
    })
}

fn mouse_button(button: MouseButton) -> &'static str {
    match button {
        MouseButton::Left => "left",
        MouseButton::Right => "right",
        MouseButton::Middle => "middle",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crossterm::event::MouseEvent;
    use ratatui::Terminal;
    use ratatui::backend::TestBackend;

    #[test]
    fn encodes_keyboard_mouse_focus_and_paste_without_losing_coordinates() {
        let key = Event::Key(KeyEvent::new(
            KeyCode::Char('x'),
            KeyModifiers::CONTROL | KeyModifiers::SHIFT,
        ));
        assert_eq!(
            encode_event(&key).unwrap(),
            json!({
                "kind": "key",
                "code": "x",
                "modifiers": ["shift", "control"],
                "event": "press"
            })
        );
        let mouse = Event::Mouse(MouseEvent {
            kind: MouseEventKind::Down(MouseButton::Right),
            column: 7,
            row: 9,
            modifiers: KeyModifiers::ALT,
        });
        assert_eq!(encode_event(&mouse).unwrap()["column"], 7);
        assert_eq!(encode_event(&mouse).unwrap()["row"], 9);
        assert_eq!(encode_event(&mouse).unwrap()["button"], "right");
        assert_eq!(
            encode_event(&Event::FocusLost).unwrap(),
            json!({"kind": "focus", "focused": false})
        );
        assert_eq!(
            encode_event(&Event::Paste("exact\npaste".to_string())).unwrap(),
            json!({"kind": "paste", "text": "exact\npaste"})
        );
    }

    #[test]
    fn widget_renders_title_lines_styles_status_and_error() {
        let model = SidebarModel {
            title: "Agents".to_string(),
            size: Some(Size::new(20, 2).unwrap()),
            cursor: Some(RenderCursor {
                x: 0,
                y: 0,
                style: cmux::RenderCursorStyle::Block,
                blink: false,
                visible: false,
                color: None,
            }),
            default_fg: Some(ColorHex::parse("#ffffff").unwrap()),
            default_bg: Some(ColorHex::parse("#000000").unwrap()),
            scrollback_rows: 0,
            rows: vec![
                RenderRow {
                    row: 0,
                    runs: vec![RenderRun {
                        text: "one".to_string(),
                        fg: Some(ColorHex::parse("#ff0000").unwrap()),
                        bg: None,
                        attrs: RenderRun::ATTR_BOLD,
                        underline: None,
                        width_hint: None,
                    }],
                },
                RenderRow {
                    row: 1,
                    runs: vec![RenderRun {
                        text: "two".to_string(),
                        fg: None,
                        bg: None,
                        attrs: 0,
                        underline: None,
                        width_hint: None,
                    }],
                },
            ],
            scroll: None,
            status: Some("live".to_string()),
            error: Some("problem".to_string()),
            unknown_events: 0,
            last_unknown: None,
        };
        let backend = TestBackend::new(24, 8);
        let mut terminal = Terminal::new(backend).unwrap();
        terminal
            .draw(|frame| {
                frame.render_widget(
                    SidebarWidget::new(&model).footer("application controls"),
                    frame.area(),
                );
            })
            .unwrap();
        let rendered = terminal
            .backend()
            .buffer()
            .content
            .iter()
            .map(|cell| cell.symbol())
            .collect::<String>();
        assert!(rendered.contains("Agents"));
        assert!(rendered.contains("one"));
        assert!(rendered.contains("live"));
        assert!(rendered.contains("problem"));
        assert!(rendered.contains("application controls"));
        let styled = terminal.backend().buffer().cell((1, 1)).unwrap();
        assert_eq!(styled.fg, Color::Rgb(255, 0, 0));
        assert!(styled.modifier.contains(Modifier::BOLD));
    }

    #[test]
    fn reducer_preserves_unknown_event_payloads_for_future_telemetry() {
        let raw = Document::from_serializable(&json!({
            "kind": "future_badge",
            "badge": {"text": "new"}
        }))
        .unwrap();
        let mut model = SidebarModel::new("Agents");
        model.apply_item(SidebarViewItem::Unknown {
            kind: "future_badge".to_string(),
            raw: raw.clone(),
        });
        assert_eq!(model.unknown_events, 1);
        assert_eq!(
            model.last_unknown,
            Some(UnknownSidebarEvent { kind: "future_badge".to_string(), raw })
        );
    }
}
