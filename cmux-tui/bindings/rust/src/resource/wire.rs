use super::id::*;
use super::model::*;
use super::options::*;
use super::typed_stream::ColorHex;
use crate::{Error, Result};
use base64::Engine;
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Map, Value, json};

pub(crate) mod field {
    pub(crate) const MACHINE: &str = "machine";
    pub(crate) const SESSION: &str = "session";
    pub(crate) const WORKSPACE: &str = "workspace";
    pub(crate) const SCREEN: &str = "screen";
    pub(crate) const PANE: &str = "pane";
    pub(crate) const TAB: &str = "tab";
    pub(crate) const TERMINAL: &str = "terminal";
    pub(crate) const BROWSER: &str = "browser";
    pub(crate) const CLIENT: &str = "client";
    pub(crate) const SPLIT_ID: &str = "split_id";
    pub(crate) const STREAM: &str = "stream";
    pub(crate) const PAIRING_REQUEST: &str = "pairing_request";
    pub(crate) const FRONTEND_PROJECTION: &str = "frontend_projection";
    pub(crate) const SIDEBAR_VIEW: &str = "sidebar_view";
    pub(crate) const STREAM_ID: &str = "stream_id";
    pub(crate) const ATTACHMENT_LEASE: &str = "attachment_lease";
    pub(crate) const NAME: &str = "name";
    pub(crate) const KIND: &str = "kind";
    pub(crate) const INDEX: &str = "index";
    pub(crate) const DIRECTION: &str = "direction";
    pub(crate) const RATIO: &str = "ratio";
    pub(crate) const VIEWPORT_WIDTH: &str = "viewport_width";
    pub(crate) const COLUMNS: &str = "columns";
    pub(crate) const COLS: &str = "cols";
    pub(crate) const ROWS: &str = "rows";
    pub(crate) const WIDTH_PX: &str = "width_px";
    pub(crate) const HEIGHT_PX: &str = "height_px";
    pub(crate) const ENABLED: &str = "enabled";
    pub(crate) const EXCLUSIVE: &str = "exclusive";
    pub(crate) const LAYOUT: &str = "layout";
    pub(crate) const ARGV: &str = "argv";
    pub(crate) const SHELL: &str = "shell";
    pub(crate) const CWD: &str = "cwd";
    pub(crate) const TEXT: &str = "text";
    pub(crate) const BYTES_BASE64: &str = "bytes_base64";
    pub(crate) const DATA_BASE64: &str = "data_base64";
    pub(crate) const KEYS: &str = "keys";
    pub(crate) const BUTTON: &str = "button";
    pub(crate) const COLUMN: &str = "column";
    pub(crate) const ROW: &str = "row";
    pub(crate) const MODIFIERS: &str = "modifiers";
    pub(crate) const DELTA_ROWS: &str = "delta_rows";
    pub(crate) const FOCUSED: &str = "focused";
    pub(crate) const BEFORE: &str = "before";
    pub(crate) const LIMIT: &str = "limit";
    pub(crate) const STYLED: &str = "styled";
    pub(crate) const PATTERN: &str = "pattern";
    pub(crate) const TIMEOUT_MS: &str = "timeout_ms";
    pub(crate) const MODE: &str = "mode";
    pub(crate) const READ_ONLY: &str = "read_only";
    pub(crate) const URL: &str = "url";
    pub(crate) const KEY: &str = "key";
    pub(crate) const DELTA_X: &str = "delta_x";
    pub(crate) const DELTA_Y: &str = "delta_y";
    pub(crate) const X_PX: &str = "x_px";
    pub(crate) const Y_PX: &str = "y_px";
    pub(crate) const POINTER_FRAME_SEQ: &str = "pointer_frame_seq";
    pub(crate) const CLICK_COUNT: &str = "click_count";
    pub(crate) const CURSOR: &str = "cursor";
    pub(crate) const TITLE: &str = "title";
    pub(crate) const BODY: &str = "body";
    pub(crate) const LEVEL: &str = "level";
    pub(crate) const TERMINAL_ID: &str = "terminal_id";
    pub(crate) const PROJECTION: &str = "projection";
    pub(crate) const FRONTEND_ID: &str = "frontend_id";
    pub(crate) const WINDOW_ID: &str = "window_id";
    pub(crate) const GENERATION: &str = "generation";
    pub(crate) const EXPECTED_PROJECTION_REVISION: &str = "expected_projection_revision";
    pub(crate) const DECISION: &str = "decision";
    pub(crate) const STATE: &str = "state";
    pub(crate) const SOURCE: &str = "source";
    pub(crate) const SOURCE_SESSION: &str = "source_session";
    pub(crate) const RELAUNCH: &str = "relaunch";
    pub(crate) const INITIAL_CONTENT: &str = "initial_content";
    pub(crate) const FORCE: &str = "force";
    pub(crate) const TTL_MS: &str = "ttl_ms";
    pub(crate) const EXPECTED_REVISION: &str = "expected_revision";
    pub(crate) const OTHER_WORKSPACE: &str = "other_workspace";
    pub(crate) const OTHER_SCREEN: &str = "other_screen";
    pub(crate) const OTHER_PANE: &str = "other_pane";
    pub(crate) const DESTINATION_WORKSPACE: &str = "destination_workspace";
    pub(crate) const DESTINATION_SCREEN: &str = "destination_screen";
    pub(crate) const DESTINATION_PANE: &str = "destination_pane";
    pub(crate) const FOREGROUND: &str = "foreground";
    pub(crate) const BACKGROUND: &str = "background";
    pub(crate) const SELECTION_BACKGROUND: &str = "selection_background";
    pub(crate) const SELECTION_FOREGROUND: &str = "selection_foreground";
    pub(crate) const CURSOR_STYLE: &str = "cursor_style";
    pub(crate) const CURSOR_BLINK: &str = "cursor_blink";
    pub(crate) const PALETTE: &str = "palette";
    pub(crate) const COMPLETE: &str = "complete";
    pub(crate) const CONFIRM_CLOSE: &str = "confirm_close";
    pub(crate) const CONFIRMATION_TOKEN: &str = "confirmation_token";
    pub(crate) const CORRELATION_KEY: &str = "correlation_key";
}

#[derive(Clone, Debug, Default)]
pub(crate) struct Params(Map<String, Value>);

impl Params {
    pub(crate) fn new() -> Self {
        Self::default()
    }

    pub(crate) fn into_value(self) -> Value {
        Value::Object(self.0)
    }

    pub(crate) fn value(mut self, key: &'static str, value: Value) -> Self {
        self.0.insert(key.to_string(), value);
        self
    }

    pub(crate) fn extend(mut self, other: Self) -> Self {
        self.0.extend(other.0);
        self
    }

    pub(crate) fn only(&self, keys: &[&'static str]) -> Self {
        Self(
            keys.iter()
                .filter_map(|key| {
                    self.0.get(*key).cloned().map(|value| ((*key).to_string(), value))
                })
                .collect(),
        )
    }

    pub(crate) fn string(self, key: &'static str, value: impl Into<String>) -> Self {
        self.value(key, Value::String(value.into()))
    }

    pub(crate) fn optional_string(self, key: &'static str, value: Option<String>) -> Self {
        match value {
            Some(value) => self.string(key, value),
            None => self,
        }
    }

    pub(crate) fn boolean(self, key: &'static str, value: bool) -> Self {
        self.value(key, Value::Bool(value))
    }

    pub(crate) fn optional_bool(self, key: &'static str, value: Option<bool>) -> Self {
        match value {
            Some(value) => self.boolean(key, value),
            None => self,
        }
    }

    pub(crate) fn u64(self, key: &'static str, value: u64) -> Self {
        self.string(key, value.to_string())
    }

    pub(crate) fn optional_u64(self, key: &'static str, value: Option<u64>) -> Self {
        match value {
            Some(value) => self.u64(key, value),
            None => self,
        }
    }

    pub(crate) fn u32(self, key: &'static str, value: u32) -> Self {
        self.value(key, Value::from(value))
    }

    pub(crate) fn optional_u32(self, key: &'static str, value: Option<u32>) -> Self {
        match value {
            Some(value) => self.u32(key, value),
            None => self,
        }
    }

    pub(crate) fn u16(self, key: &'static str, value: u16) -> Self {
        self.value(key, Value::from(value))
    }

    pub(crate) fn i32(self, key: &'static str, value: i32) -> Self {
        self.value(key, Value::from(value))
    }

    pub(crate) fn optional_i32(self, key: &'static str, value: Option<i32>) -> Self {
        match value {
            Some(value) => self.i32(key, value),
            None => self,
        }
    }

    pub(crate) fn f64(self, key: &'static str, value: f64) -> Self {
        self.value(key, json!(value))
    }

    pub(crate) fn optional_f64(self, key: &'static str, value: Option<f64>) -> Self {
        match value {
            Some(value) => self.f64(key, value),
            None => self,
        }
    }

    pub(crate) fn selector<I: OpaqueId>(self, key: &'static str, selector: &Selector<I>) -> Self {
        self.string(key, selector_wire(selector))
    }

    pub(crate) fn optional_selector<I: OpaqueId>(
        self,
        key: &'static str,
        selector: Option<&Selector<I>>,
    ) -> Self {
        match selector {
            Some(selector) => self.selector(key, selector),
            None => self,
        }
    }

    pub(crate) fn id<I: OpaqueId>(self, key: &'static str, id: &I) -> Self {
        self.string(key, id.as_str())
    }

    pub(crate) fn optional_id<I: OpaqueId>(self, key: &'static str, id: Option<&I>) -> Self {
        match id {
            Some(id) => self.id(key, id),
            None => self,
        }
    }

    pub(crate) fn cursor(self, cursor: Option<&Cursor>) -> Self {
        match cursor {
            Some(cursor) => self.value(
                field::CURSOR,
                json!({
                    "generation": cursor.generation,
                    "revision": cursor.revision.to_string(),
                }),
            ),
            None => self,
        }
    }

    pub(crate) fn cancellation_scope(&self, stream_id: &StreamId) -> Self {
        let machine = self
            .0
            .get(field::MACHINE)
            .cloned()
            .unwrap_or_else(|| Value::String("current".to_string()));
        let session = self
            .0
            .get(field::SESSION)
            .cloned()
            .unwrap_or_else(|| Value::String("current".to_string()));
        Self::new()
            .value(field::MACHINE, machine)
            .value(field::SESSION, session)
            .id(field::STREAM, stream_id)
    }
}

pub(crate) fn selector_wire<I: OpaqueId>(selector: &Selector<I>) -> String {
    match selector {
        Selector::Id(id) => id.as_str().to_string(),
        Selector::Current(_) => "current".to_string(),
        Selector::Name(name) => format!("name:{name}"),
    }
}

pub(crate) fn size(params: Params, value: Option<Size>) -> Result<Params> {
    match value {
        Some(value) => {
            validate_size(value)?;
            Ok(params.u16(field::COLS, value.cols).u16(field::ROWS, value.rows))
        }
        None => Ok(params),
    }
}

pub(crate) fn pixel_size(params: Params, value: Option<PixelSize>) -> Result<Params> {
    match value {
        Some(value) => {
            validate_pixel_size(value)?;
            Ok(params.u32(field::WIDTH_PX, value.width_px).u32(field::HEIGHT_PX, value.height_px))
        }
        None => Ok(params),
    }
}

pub(crate) fn validate_size(value: Size) -> Result<()> {
    if value.cols == 0 || value.rows == 0 {
        return Err(Error::InvalidArgument(
            "terminal dimensions must be greater than zero".to_string(),
        ));
    }
    Ok(())
}

pub(crate) fn validate_pixel_size(value: PixelSize) -> Result<()> {
    if value.width_px == 0 || value.height_px == 0 {
        return Err(Error::InvalidArgument(
            "pixel dimensions must be greater than zero".to_string(),
        ));
    }
    Ok(())
}

pub(crate) fn validate_ratio(value: f64) -> Result<()> {
    if !value.is_finite() || value <= 0.0 || value >= 1.0 {
        return Err(Error::InvalidArgument(
            "split ratio must be finite and between zero and one".to_string(),
        ));
    }
    Ok(())
}

fn validate_viewport_width(direction: Direction, value: f64) -> Result<()> {
    if direction != Direction::Right || !value.is_finite() || !(0.1..=1.0).contains(&value) {
        return Err(Error::InvalidArgument(
            "viewport width requires a right split and a finite value between 0.1 and 1"
                .to_string(),
        ));
    }
    Ok(())
}

fn creation_correlation(params: Params, correlation_key: Option<String>) -> Result<Params> {
    if let Some(value) = &correlation_key {
        validate_correlation_key(value)?;
    }
    Ok(params.optional_string(field::CORRELATION_KEY, correlation_key))
}

pub(crate) fn create_workspace(options: CreateWorkspaceOptions) -> Result<Params> {
    let params = Params::new().optional_string(field::NAME, options.name).string(
        field::INITIAL_CONTENT,
        match options.initial_content {
            InitialContent::Terminal => "terminal",
            InitialContent::Empty => "empty",
        },
    );
    creation_correlation(params, options.correlation_key)
}

pub(crate) fn create_screen(options: CreateScreenOptions) -> Result<Params> {
    creation_correlation(
        Params::new().optional_string(field::NAME, options.name),
        options.correlation_key,
    )
}

pub(crate) fn create_pane(options: CreatePaneOptions) -> Result<Params> {
    let params = size(Params::new().optional_string(field::CWD, options.cwd), options.size)?;
    creation_correlation(params, options.correlation_key)
}

pub(crate) fn run(options: RunOptions) -> Result<Params> {
    let params = size(
        Params::new()
            .optional_string(field::CWD, options.cwd)
            .optional_string(field::NAME, options.name),
        options.size,
    )?;
    let params = match options.command {
        RunCommand::Exact { argv } => {
            params.value(field::ARGV, Value::Array(argv.into_iter().map(Value::String).collect()))
        }
        RunCommand::Shell { script } => params.string(field::SHELL, script),
    };
    creation_correlation(params, options.correlation_key)
}

pub(crate) fn split(options: SplitOptions) -> Result<Params> {
    if let Some(ratio) = options.ratio {
        validate_ratio(ratio)?;
    }
    if let Some(width) = options.viewport_width {
        validate_viewport_width(options.direction, width)?;
    }
    let params = size(
        Params::new()
            .string(field::DIRECTION, options.direction.wire_name())
            .optional_f64(field::RATIO, options.ratio)
            .optional_f64(field::VIEWPORT_WIDTH, options.viewport_width)
            .optional_string(field::CWD, options.cwd),
        options.size,
    )?;
    creation_correlation(params, options.correlation_key)
}

pub(crate) fn terminal_create(options: TerminalCreateOptions) -> Result<Params> {
    let params = size(
        Params::new()
            .optional_string(field::CWD, options.cwd)
            .optional_string(field::NAME, options.name),
        options.size,
    )?;
    creation_correlation(params, options.correlation_key)
}

pub(crate) fn browser_create(options: BrowserCreateOptions) -> Result<Params> {
    if options.url.is_empty() {
        return Err(Error::InvalidArgument("browser URL must not be empty".to_string()));
    }
    let params = pixel_size(
        Params::new().string(field::URL, options.url).optional_string(field::NAME, options.name),
        options.size,
    )?;
    creation_correlation(params, options.correlation_key)
}

pub(crate) fn terminal_attach(options: TerminalAttachOptions) -> Result<Params> {
    size(Params::new().optional_bool(field::READ_ONLY, options.read_only), options.size)
}

pub(crate) fn browser_attach(options: BrowserAttachOptions) -> Result<Params> {
    pixel_size(Params::new(), options.size)
}

pub(crate) fn terminal_mouse(options: TerminalMouseOptions) -> Result<Params> {
    match options.kind {
        TerminalMouseKind::Down | TerminalMouseKind::Up => {
            if options.button.is_none() || options.delta_rows.is_some() {
                return Err(Error::InvalidArgument(
                    "terminal mouse down/up require a button and forbid delta_rows".to_string(),
                ));
            }
        }
        TerminalMouseKind::Move => {
            if options.button.is_some() || options.delta_rows.is_some() {
                return Err(Error::InvalidArgument(
                    "terminal mouse move forbids button and delta_rows".to_string(),
                ));
            }
        }
        TerminalMouseKind::Wheel => {
            if options.button.is_some() || options.delta_rows.is_none_or(|delta| delta == 0) {
                return Err(Error::InvalidArgument(
                    "terminal mouse wheel requires nonzero delta_rows and forbids button"
                        .to_string(),
                ));
            }
        }
    }
    Ok(Params::new()
        .string(field::KIND, options.kind.wire_name())
        .u16(field::ROW, options.row)
        .u16(field::COLUMN, options.column)
        .optional_string(field::BUTTON, options.button.map(|button| button.wire_name().to_string()))
        .optional_i32(field::DELTA_ROWS, options.delta_rows)
        .value(
            field::MODIFIERS,
            Value::Array(
                options
                    .modifiers
                    .into_iter()
                    .map(|modifier| Value::String(modifier.wire_name().to_string()))
                    .collect(),
            ),
        ))
}

pub(crate) fn browser_key(options: BrowserKeyOptions) -> Result<Params> {
    if options.key.is_empty() {
        return Err(Error::InvalidArgument("browser key must not be empty".to_string()));
    }
    Ok(Params::new()
        .string(field::KEY, options.key)
        .optional_string(field::KIND, options.kind.map(|kind| kind.wire_name().to_string()))
        .value(
            field::MODIFIERS,
            Value::Array(
                options
                    .modifiers
                    .into_iter()
                    .map(|modifier| Value::String(modifier.wire_name().to_string()))
                    .collect(),
            ),
        ))
}

pub(crate) fn browser_mouse(options: BrowserMouseOptions) -> Result<Params> {
    if !options.x_px.is_finite() || !options.y_px.is_finite() {
        return Err(Error::InvalidArgument("browser mouse coordinates must be finite".to_string()));
    }
    match options.kind {
        BrowserMouseKind::Down | BrowserMouseKind::Up if options.button.is_none() => {
            return Err(Error::InvalidArgument(
                "browser mouse down/up require a button".to_string(),
            ));
        }
        BrowserMouseKind::Move if options.button.is_some() || options.click_count.is_some() => {
            return Err(Error::InvalidArgument(
                "browser mouse move forbids button and click_count".to_string(),
            ));
        }
        _ => {}
    }
    Ok(Params::new()
        .string(field::KIND, options.kind.wire_name())
        .f64(field::X_PX, options.x_px)
        .f64(field::Y_PX, options.y_px)
        .u64(field::POINTER_FRAME_SEQ, options.pointer_frame_seq)
        .optional_string(field::BUTTON, options.button.map(|button| button.wire_name().to_string()))
        .optional_u32(field::CLICK_COUNT, options.click_count))
}

pub(crate) fn wheel(options: WheelOptions) -> Result<Params> {
    if !options.delta_x.is_finite()
        || !options.delta_y.is_finite()
        || !options.x_px.is_finite()
        || !options.y_px.is_finite()
    {
        return Err(Error::InvalidArgument(
            "browser wheel coordinates and deltas must be finite".to_string(),
        ));
    }
    Ok(Params::new()
        .f64(field::DELTA_X, options.delta_x)
        .f64(field::DELTA_Y, options.delta_y)
        .f64(field::X_PX, options.x_px)
        .f64(field::Y_PX, options.y_px)
        .u64(field::POINTER_FRAME_SEQ, options.pointer_frame_seq))
}

pub(crate) fn move_destination(options: MoveDestination) -> Params {
    Params::new()
        .selector(field::DESTINATION_WORKSPACE, &options.workspace)
        .selector(field::DESTINATION_SCREEN, &options.screen)
        .selector(field::DESTINATION_PANE, &options.pane)
        .u32(field::INDEX, options.index)
}

pub(crate) fn terminal_project(options: TerminalProjectOptions) -> Params {
    move_destination(options.destination).optional_string(field::NAME, options.name)
}

pub(crate) fn pane_swap(options: PaneSwapOptions) -> Params {
    Params::new()
        .selector(field::OTHER_WORKSPACE, &options.other_workspace)
        .selector(field::OTHER_SCREEN, &options.other_screen)
        .selector(field::OTHER_PANE, &options.other_pane)
}

pub(crate) fn terminal_defaults(options: TerminalDefaultsOptions) -> Result<Params> {
    fn color_update(params: Params, key: &'static str, value: Update<ColorHex>) -> Params {
        match value {
            Update::Unchanged => params,
            Update::Clear => params.value(key, Value::Null),
            Update::Set(value) => params.string(key, value.as_str()),
        }
    }

    let changed = !matches!(&options.foreground, Update::Unchanged)
        || !matches!(&options.background, Update::Unchanged)
        || !matches!(&options.cursor, Update::Unchanged)
        || !matches!(&options.selection_background, Update::Unchanged)
        || !matches!(&options.selection_foreground, Update::Unchanged)
        || !matches!(&options.cursor_style, Update::Unchanged)
        || !matches!(&options.cursor_blink, Update::Unchanged)
        || !matches!(&options.palette, Update::Unchanged)
        || options.complete.is_some();
    if !changed {
        return Err(Error::InvalidArgument(
            "terminal defaults update must change at least one field".to_string(),
        ));
    }

    let params = color_update(Params::new(), field::FOREGROUND, options.foreground);
    let params = color_update(params, field::BACKGROUND, options.background);
    let params = color_update(params, field::CURSOR, options.cursor);
    let params = color_update(params, field::SELECTION_BACKGROUND, options.selection_background);
    let params = color_update(params, field::SELECTION_FOREGROUND, options.selection_foreground);
    let params = match options.cursor_style {
        Update::Unchanged => params,
        Update::Clear => params.value(field::CURSOR_STYLE, Value::Null),
        Update::Set(value) => params.string(field::CURSOR_STYLE, value.wire_name()),
    };
    let params = match options.cursor_blink {
        Update::Unchanged => params,
        Update::Clear => params.value(field::CURSOR_BLINK, Value::Null),
        Update::Set(value) => params.boolean(field::CURSOR_BLINK, value),
    };
    let params = match options.palette {
        Update::Unchanged => params,
        Update::Clear => params.value(field::PALETTE, Value::Null),
        Update::Set(value) => params.value(
            field::PALETTE,
            Value::Object(
                value
                    .into_iter()
                    .map(|(key, value)| {
                        (key.to_string(), Value::String(value.as_str().to_string()))
                    })
                    .collect(),
            ),
        ),
    };
    Ok(params.optional_bool(field::COMPLETE, options.complete))
}

pub(crate) fn layout_document(document: LayoutDocument) -> Result<Value> {
    document.validate()?;
    serde_json::to_value(document).map_err(|error| Error::Decode(error.to_string()))
}

pub(crate) fn sidebar_input(options: SidebarInputOptions) -> Params {
    Params::new()
        .string(field::DATA_BASE64, base64::engine::general_purpose::STANDARD.encode(options.data))
}

pub(crate) fn parse_decimal(value: &Value, context: &str) -> Result<u64> {
    let Some(value) = value.as_str() else {
        return Err(Error::UnexpectedEnvelope(format!("{context} must be a decimal string")));
    };
    if value.is_empty()
        || value.starts_with('+')
        || (value.starts_with('0') && value.len() > 1)
        || !value.bytes().all(|byte| byte.is_ascii_digit())
    {
        return Err(Error::UnexpectedEnvelope(format!("{context} is not canonical decimal")));
    }
    value.parse::<u64>().map_err(|_| Error::UnexpectedEnvelope(format!("{context} exceeds u64")))
}

pub(crate) fn parse_cursor(value: &Value) -> Result<Cursor> {
    decode_exact(value, "cursor")
}

pub(crate) fn mutation_meta(value: &Value) -> Result<MutationReceipt> {
    let object = value.as_object().ok_or_else(|| {
        Error::UnexpectedEnvelope("mutation result must be an object".to_string())
    })?;
    if object.get("value").is_none() {
        return Err(Error::UnexpectedEnvelope("mutation result value is required".to_string()));
    }
    let generation = object
        .get("generation")
        .and_then(Value::as_str)
        .ok_or_else(|| {
            Error::UnexpectedEnvelope("mutation generation must be a string".to_string())
        })?
        .to_string();
    if generation.is_empty() || generation.len() > 128 {
        return Err(Error::UnexpectedEnvelope(
            "mutation generation must contain 1 to 128 bytes".to_string(),
        ));
    }
    let revision = parse_decimal(
        object.get("revision").ok_or_else(|| {
            Error::UnexpectedEnvelope("mutation revision is required".to_string())
        })?,
        "mutation revision",
    )?;
    let replayed = object.get("replayed").and_then(Value::as_bool).ok_or_else(|| {
        Error::UnexpectedEnvelope("mutation replayed must be a boolean".to_string())
    })?;
    let unknown = object
        .keys()
        .filter(|key| !matches!(key.as_str(), "value" | "generation" | "revision" | "replayed"))
        .cloned()
        .collect::<Vec<_>>();
    if !unknown.is_empty() {
        return Err(Error::UnexpectedEnvelope(format!(
            "mutation result contains unknown fields: {}",
            unknown.join(", ")
        )));
    }
    Ok(MutationResult { value: (), generation, revision, replayed })
}

pub(crate) fn mutation_value(value: &Value) -> Result<&Value> {
    value
        .as_object()
        .and_then(|object| object.get("value"))
        .ok_or_else(|| Error::UnexpectedEnvelope("mutation result value is required".to_string()))
}

pub(crate) fn created_path(value: &Value) -> Result<CreatedPath> {
    let object = value
        .as_object()
        .ok_or_else(|| Error::UnexpectedEnvelope("created path must be an object".to_string()))?;
    let kind = object
        .get("kind")
        .and_then(Value::as_str)
        .ok_or_else(|| Error::UnexpectedEnvelope("created path kind is required".to_string()))?;
    let workspace_id = find_required_id(value, "workspace_id")?;
    let (allowed, path) = match kind {
        "workspace" => (&["kind", "workspace_id"][..], CreatedPath::Workspace { workspace_id }),
        "terminal" => (
            &["kind", "workspace_id", "screen_id", "pane_id", "tab_id", "terminal_id"][..],
            CreatedPath::Terminal {
                workspace_id,
                screen_id: find_required_id(value, "screen_id")?,
                pane_id: find_required_id(value, "pane_id")?,
                tab_id: find_required_id(value, "tab_id")?,
                terminal_id: find_required_id(value, "terminal_id")?,
            },
        ),
        "browser" => (
            &["kind", "workspace_id", "screen_id", "pane_id", "tab_id", "browser_id"][..],
            CreatedPath::Browser {
                workspace_id,
                screen_id: find_required_id(value, "screen_id")?,
                pane_id: find_required_id(value, "pane_id")?,
                tab_id: find_required_id(value, "tab_id")?,
                browser_id: find_required_id(value, "browser_id")?,
            },
        ),
        other => {
            return Err(Error::UnexpectedEnvelope(format!("unknown created path kind {other}")));
        }
    };
    let unknown =
        object.keys().filter(|key| !allowed.contains(&key.as_str())).cloned().collect::<Vec<_>>();
    if !unknown.is_empty() {
        return Err(Error::UnexpectedEnvelope(format!(
            "created path contains unknown fields: {}",
            unknown.join(", ")
        )));
    }
    Ok(path)
}

pub(crate) fn decode_exact<T: DeserializeOwned>(value: &Value, context: &str) -> Result<T> {
    serde_json::from_value(value.clone())
        .map_err(|error| Error::UnexpectedEnvelope(format!("invalid {context}: {error}")))
}

pub(crate) fn snapshot<T: DeserializeOwned>(
    value: &Value,
    resource_key: &'static str,
) -> Result<T> {
    decode_exact(value, resource_key)
}

pub(crate) fn list<T: DeserializeOwned>(
    value: &Value,
    collection_key: &'static str,
    resource_key: &'static str,
) -> Result<Vec<T>> {
    let values = value.as_array().ok_or_else(|| {
        Error::UnexpectedEnvelope(format!("{collection_key} result must be an array"))
    })?;
    values.iter().map(|value| snapshot(value, resource_key)).collect()
}

pub(crate) fn terminal_history(value: &Value) -> Result<TerminalHistoryResult> {
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Wire {
        start: Value,
        #[serde(default)]
        next: Option<Value>,
        rows: Vec<Value>,
    }

    let wire: Wire = decode_exact(value, "terminal history result")?;
    let start = parse_decimal(&wire.start, "terminal history start")?;
    let next = wire
        .next
        .as_ref()
        .map(|value| parse_decimal(value, "terminal history next"))
        .transpose()?;
    let rows = wire
        .rows
        .into_iter()
        .map(super::typed_stream::decode_render_row)
        .collect::<Result<Vec<_>>>()?;
    Ok(TerminalHistoryResult { start, next, rows })
}

fn find_id<I: OpaqueId>(value: &Value, keys: &[&str]) -> Result<Option<I>> {
    let Some(object) = value.as_object() else {
        return Ok(None);
    };
    for key in keys {
        if let Some(value) = object.get(*key) {
            return match value {
                Value::String(value) => I::parse(value.clone()).map(Some),
                Value::Null => Ok(None),
                _ => Err(Error::UnexpectedEnvelope(format!("{key} must contain an ID"))),
            };
        }
    }
    Ok(None)
}

fn find_required_id<I: OpaqueId>(value: &Value, key: &str) -> Result<I> {
    find_id(value, &[key])?
        .ok_or_else(|| Error::UnexpectedEnvelope(format!("created path {key} is required")))
}
