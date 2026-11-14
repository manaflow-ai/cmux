//! The Mac's theme and wallpaper on the phone (ask-87d30da8e5): the iPhone app's chrome takes
//! the colors the Mac app's chrome derives from (the terminal theme, or `appearance.appTheme`,
//! with `appearance.accent`) and shows the picture the Mac's windows show behind its sidebar.
//!
//! The Mac app resolves both (libghostty reads the config; only the app resolves a Desktop
//! Picture, an Apple wallpaper or a video's poster) and hands hostd what it shows over stdin:
//! `{"type":"appearance","theme":{...},"wallpaper":{"path","tint_opacity"}}`, the whole state
//! each time it changes. hostd keeps every rule here:
//!
//! - the theme is checked (`#rrggbb` colors, 8 or 16 palette entries, a known accent, opacities
//!   in 0...1) and served whole on the `appearance` service, one JSON object now and on every
//!   change (`{"theme":{...},"wallpaper":{"id","bytes","tint_opacity"}}`);
//! - the wallpaper file is read once, at most [`MAX_WALLPAPER_BYTES`], a JPEG or PNG only, and
//!   named by its content (`id`: SHA-256, hex), so a phone that already has `id` cached never
//!   fetches it again; `appearance-wallpaper {"id"}` streams the bytes of the current one and
//!   refuses `stale` for any other id.
//!
//! The phone derives every chrome color from the theme itself (`ThemeTokens.derive`, the same
//! code the Mac runs), so it computes the same palette offline from its cached copy.
//!
//! The terminal theme travels apart from the chrome's (`terminal`): the value of each key in
//! [`TERMINAL_KEYS`] in the Mac's applied Ghostty config (`key = value` lines). The phone loads exactly these lines into every terminal of this Mac, after resetting
//! each key, so its terminals show the Mac's terminal theme and nothing of their own. Lines with
//! another key or an unexpected value are dropped here.
//!
//! The rest of the Mac's look travels apart too (`look`, every field optional): its window
//! style (`appearance.chromeStyle`, two-tone included), hue and saturation, glass transparency,
//! sidebar surface, terminal font, chat bubble colors and the sidebar's group palette and
//! gradient. Each field is checked on its own ([`sanitize_look`]): a bad one is dropped and the
//! rest, and the theme, still serve. An app that sends none (or none valid) gets a message
//! without `look`, byte for byte the message from before `look` existed.

use std::sync::OnceLock;

use bytes::Bytes;
use cmux_mobile_link::ChannelEvent;
use cmux_mobile_link::link::{ChannelReceiver, ChannelSender};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use tokio::sync::watch;

use crate::services::Refusal;

/// The largest wallpaper served (the app sends a phone-sized JPEG, about 0.5 MB).
pub const MAX_WALLPAPER_BYTES: u64 = 8 << 20;
/// One wallpaper message on the `appearance-wallpaper` channel.
const WALLPAPER_CHUNK: usize = 64 * 1024;
/// `appearance.accent` values (`CmuxTheme.ThemeAccent`); `art` is the Mac's Art Color, which
/// it resolves to `accent_color` before sending.
const ACCENTS: [&str; 9] = ["neutral", "theme", "red", "green", "yellow", "blue", "magenta", "cyan", "art"];

/// The Ghostty keys of the terminal theme the phone takes from the Mac. The Mac sends these
/// (`GhosttyRuntime.phoneTerminalThemeKeys`) and the phone resets and loads these
/// (`CmuxMobileTerminalTheme.keys`); keep the three lists the same.
pub const TERMINAL_KEYS: [&str; 19] = [
    "background",
    "foreground",
    "palette",
    "cursor-color",
    "cursor-text",
    "cursor-opacity",
    "selection-background",
    "selection-foreground",
    "bold-color",
    "minimum-contrast",
    "faint-opacity",
    "palette-generate",
    "palette-harmonious",
    "alpha-blending",
    "window-colorspace",
    "search-background",
    "search-foreground",
    "search-selected-background",
    "search-selected-foreground",
];
/// `appearance.chromeStyle` values (`ChromeStyle`, schemas/settings/chrome-styles.json).
pub const CHROME_STYLES: [&str; 10] = [
    "default",
    "card",
    "card-outlined",
    "flat",
    "flat-sidebar-line",
    "bare",
    "panes",
    "two-tone",
    "floating",
    "blocks",
];
/// `appearance.sidebarSurface` values (`SidebarSurface`).
pub const SIDEBAR_SURFACES: [&str; 2] = ["same", "separate"];
/// `sidebar.groupPalette` values (`GroupPalette`).
pub const GROUP_PALETTES: [&str; 7] =
    ["glass", "theme", "wallpaper", "grayscale", "vibrant", "gradient", "pictorial"];
/// `sidebar.groupGradient` values (`GroupGradient`).
pub const GROUP_GRADIENTS: [&str; 4] = ["sunset", "aurora", "lagoon", "twoTone"];
/// `terminal.fontSize` bounds in points (schemas/settings/source/terminal.json).
pub const FONT_SIZES: std::ops::RangeInclusive<f64> = 4.0..=96.0;
/// The longest family name kept (`TerminalFontSetting.maximumFamilyLength`).
const MAX_FONT_FAMILY: usize = 120;
/// The most terminal theme lines kept (256 palette entries plus the other keys).
const MAX_TERMINAL_LINES: usize = 320;
/// The longest value kept on one line.
const MAX_TERMINAL_VALUE: usize = 64;

/// The colors the Mac's chrome derives from (`ThemeInput`), as `#rrggbb`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Theme {
    pub background: String,
    pub foreground: String,
    /// ANSI 0...15 (8 or 16 entries).
    pub palette: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub selection_background: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub selection_foreground: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cursor: Option<String>,
    /// `appearance.accent`.
    #[serde(default = "neutral")]
    pub accent: String,
    /// The theme's own accent (`<theme>/accent`, `# cmux-accent`, or the art's hue).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub accent_color: Option<String>,
    /// `background-opacity` with `appearance.backgroundOpacity` over it, 0...1.
    #[serde(default = "opaque")]
    pub background_opacity: f64,
}

// JSON has no NaN, and `sanitize` drops any non-finite value: equality is total here.
impl Eq for Theme {}

fn neutral() -> String {
    "neutral".into()
}

fn opaque() -> f64 {
    1.0
}

/// The picture the Mac's windows show, as the app hands it over.
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct WallpaperFile {
    /// A phone-sized JPEG or PNG the app wrote (never a path a phone names).
    pub path: String,
    /// The tint the Mac lays over the picture (`WindowBackdrop`), 0...1.
    #[serde(default)]
    pub tint_opacity: f64,
}

impl Eq for WallpaperFile {}

/// The `appearance` control line.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct FromApp {
    pub theme: Theme,
    #[serde(default)]
    pub wallpaper: Option<WallpaperFile>,
    /// The Mac's terminal theme as Ghostty config lines; absent from an app that predates it.
    #[serde(default)]
    pub terminal: Option<Vec<String>>,
    /// The rest of the Mac's look as the app sent it, checked field by field in
    /// [`sanitize_look`] (so one bad field never costs the line); absent from an older app.
    #[serde(default)]
    pub look: Option<Value>,
}

/// The terminal's font as the Mac's terminals draw it.
#[derive(Debug, Clone, PartialEq, Default, Serialize)]
pub struct TerminalFont {
    /// The family (`terminal.fontFamily`, else the Ghostty config's `font-family`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub family: Option<String>,
    /// Points in [`FONT_SIZES`] (`terminal.fontSize`, else the Ghostty config's `font-size`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub size: Option<f64>,
}

/// The Home chat bubble colors (`home.bubbleColors.*`), `#rrggbb`.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize)]
pub struct ChatColors {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sent: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sent_text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub received: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub received_text: Option<String>,
}

/// How the sidebar colors its groups.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize)]
pub struct GroupColors {
    /// `sidebar.groupPalette`, one of [`GROUP_PALETTES`].
    #[serde(skip_serializing_if = "Option::is_none")]
    pub palette: Option<String>,
    /// `sidebar.groupGradient`, one of [`GROUP_GRADIENTS`].
    #[serde(skip_serializing_if = "Option::is_none")]
    pub gradient: Option<String>,
}

/// The Mac's look beyond its colors, every field optional (absent: the phone's own default).
#[derive(Debug, Clone, PartialEq, Default, Serialize)]
pub struct Look {
    /// `appearance.chromeStyle`, one of [`CHROME_STYLES`].
    #[serde(skip_serializing_if = "Option::is_none")]
    pub chrome_style: Option<String>,
    /// `appearance.hue`, 0...1 (0.5 keeps the theme's hue).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hue: Option<f64>,
    /// `appearance.saturation`, 0...2 (1 keeps the theme's saturation).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub saturation: Option<f64>,
    /// `appearance.glassTransparency`, 0...1.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub glass_transparency: Option<f64>,
    /// `appearance.sidebarSurface`, one of [`SIDEBAR_SURFACES`].
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sidebar_surface: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub terminal_font: Option<TerminalFont>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub chat: Option<ChatColors>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub groups: Option<GroupColors>,
}

// `sanitize_look` keeps only finite numbers: equality is total here.
impl Eq for TerminalFont {}
impl Eq for Look {}

/// What a phone is told about the wallpaper.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct WallpaperInfo {
    /// SHA-256 of the bytes, hex: the phone's cache key.
    pub id: String,
    pub bytes: u64,
    pub tint_opacity: f64,
}

/// The current appearance: what the `appearance` service sends, and the wallpaper's bytes.
#[derive(Debug, Clone, PartialEq)]
pub struct Current {
    pub theme: Theme,
    pub wallpaper: Option<(WallpaperInfo, Bytes)>,
    /// The terminal theme lines ([`sanitize_terminal`]), None from an app that sends none.
    pub terminal: Option<Vec<String>>,
    /// The rest of the look ([`sanitize_look`]), None when the app sent no valid field.
    pub look: Option<Look>,
}

impl Current {
    /// The `appearance` message.
    pub fn message(&self) -> Value {
        let mut message = serde_json::json!({
            "theme": self.theme,
            "wallpaper": self.wallpaper.as_ref().map(|(info, _)| info),
        });
        if let Some(terminal) = &self.terminal {
            message["terminal"] = serde_json::json!(terminal);
        }
        if let Some(look) = &self.look {
            message["look"] = serde_json::json!(look);
        }
        message
    }
}

/// One terminal theme line made safe to serve: `key = value` with a key of [`TERMINAL_KEYS`] and
/// a value of letters, digits and `#=:.,_-` (a color, a number, a flag, an enum name, a palette
/// entry `N=#rrggbb`), or empty (Ghostty's default). None for anything else.
fn terminal_line(line: &str) -> Option<String> {
    let (key, value) = line.split_once('=')?;
    let key = key.trim();
    let value = value.trim();
    if !TERMINAL_KEYS.contains(&key) || value.len() > MAX_TERMINAL_VALUE {
        return None;
    }
    let allowed = |b: u8| b.is_ascii_alphanumeric() || b"#=:.,_-".contains(&b);
    if !value.bytes().all(allowed) {
        return None;
    }
    Some(if value.is_empty() { format!("{key} =") } else { format!("{key} = {value}") })
}

/// The app's terminal theme lines made safe to serve: only well-formed lines of
/// [`TERMINAL_KEYS`], at most [`MAX_TERMINAL_LINES`]. None when the lines name no background and
/// foreground: the phone then keeps the Mac's chrome-derived colors.
pub fn sanitize_terminal(lines: Vec<String>) -> Option<Vec<String>> {
    let kept: Vec<String> =
        lines.iter().filter_map(|line| terminal_line(line)).take(MAX_TERMINAL_LINES).collect();
    let has = |key: &str| kept.iter().any(|line| line.starts_with(&format!("{key} = ")));
    (has("background") && has("foreground")).then_some(kept)
}

fn hex_color(value: &str) -> Option<String> {
    let digits = value.strip_prefix('#')?;
    (digits.len() == 6 && digits.bytes().all(|b| b.is_ascii_hexdigit()))
        .then(|| format!("#{}", digits.to_ascii_lowercase()))
}

fn unit(value: f64) -> Option<f64> {
    value.is_finite().then(|| value.clamp(0.0, 1.0))
}

/// The app's theme made safe to serve: every color `#rrggbb` (lowercase), 8 or 16 palette
/// entries (more are cut to 16), a known accent (else `neutral`), opacities in 0...1. None when a
/// required color is missing or malformed: the phone then keeps what it had.
pub fn sanitize(theme: Theme) -> Option<Theme> {
    let background = hex_color(&theme.background)?;
    let foreground = hex_color(&theme.foreground)?;
    let palette: Vec<String> = theme.palette.iter().take(16).map(|c| hex_color(c)).collect::<Option<_>>()?;
    if palette.len() != 8 && palette.len() != 16 {
        return None;
    }
    let optional = |c: Option<String>| c.as_deref().and_then(hex_color);
    Some(Theme {
        background,
        foreground,
        palette,
        selection_background: optional(theme.selection_background),
        selection_foreground: optional(theme.selection_foreground),
        cursor: optional(theme.cursor),
        accent: if ACCENTS.contains(&theme.accent.as_str()) { theme.accent } else { neutral() },
        accent_color: optional(theme.accent_color),
        background_opacity: unit(theme.background_opacity)?,
    })
}

/// The text of `value` when it is one of `known`.
fn choice(value: Option<&Value>, known: &[&str]) -> Option<String> {
    value.and_then(Value::as_str).filter(|text| known.contains(text)).map(str::to_owned)
}

/// A finite number in `range`. One outside is dropped, not clamped: the Mac never draws such a
/// value, so the sender is broken and the phone keeps its default.
fn number(value: Option<&Value>, range: std::ops::RangeInclusive<f64>) -> Option<f64> {
    value.and_then(Value::as_f64).filter(|n| n.is_finite() && range.contains(n))
}

/// A family name as Ghostty's override writes it (`TerminalFontSetting.isValidFamily`): trimmed,
/// 1 to [`MAX_FONT_FAMILY`] characters, none a control character, `#`, `=` or `"`.
fn font_family(value: Option<&Value>) -> Option<String> {
    let family = value.and_then(Value::as_str)?.trim();
    let allowed = |c: char| !c.is_control() && !matches!(c, '#' | '=' | '"');
    (!family.is_empty() && family.chars().count() <= MAX_FONT_FAMILY && family.chars().all(allowed))
        .then(|| family.to_owned())
}

/// The app's `look` made safe to serve: each field kept only when valid (a known enum value, a
/// number in range, a `#rrggbb` color, a plain family name, a size in [`FONT_SIZES`]); a nested
/// object with no valid field is left out. None when nothing is left.
pub fn sanitize_look(look: &Value) -> Option<Look> {
    let field = |name: &str| look.get(name);
    let inner = |object: &str, name: &str| look.get(object).and_then(|o| o.get(name));
    let color = |name: &str| inner("chat", name).and_then(Value::as_str).and_then(hex_color);
    let terminal_font = TerminalFont {
        family: font_family(inner("terminal_font", "family")),
        size: number(inner("terminal_font", "size"), FONT_SIZES),
    };
    let chat = ChatColors {
        sent: color("sent"),
        sent_text: color("sent_text"),
        received: color("received"),
        received_text: color("received_text"),
    };
    let groups = GroupColors {
        palette: choice(inner("groups", "palette"), &GROUP_PALETTES),
        gradient: choice(inner("groups", "gradient"), &GROUP_GRADIENTS),
    };
    let look = Look {
        chrome_style: choice(field("chrome_style"), &CHROME_STYLES),
        hue: number(field("hue"), 0.0..=1.0),
        saturation: number(field("saturation"), 0.0..=2.0),
        glass_transparency: number(field("glass_transparency"), 0.0..=1.0),
        sidebar_surface: choice(field("sidebar_surface"), &SIDEBAR_SURFACES),
        terminal_font: (terminal_font != TerminalFont::default()).then_some(terminal_font),
        chat: (chat != ChatColors::default()).then_some(chat),
        groups: (groups != GroupColors::default()).then_some(groups),
    };
    (look != Look::default()).then_some(look)
}

/// Whether `bytes` start as a JPEG or a PNG.
pub fn is_picture(bytes: &[u8]) -> bool {
    bytes.starts_with(&[0xFF, 0xD8, 0xFF]) || bytes.starts_with(b"\x89PNG\r\n\x1a\n")
}

/// The wallpaper at `file`, checked and named by its content; None when it cannot be served.
pub async fn read_wallpaper(file: &WallpaperFile) -> Option<(WallpaperInfo, Bytes)> {
    let path = std::path::Path::new(&file.path);
    if !path.is_absolute() {
        return None;
    }
    let metadata = tokio::fs::metadata(path).await.ok()?;
    if !metadata.is_file() || metadata.len() == 0 || metadata.len() > MAX_WALLPAPER_BYTES {
        tracing::warn!(bytes = metadata.len(), "the Mac's wallpaper is not a servable file");
        return None;
    }
    let bytes = tokio::fs::read(path).await.ok()?;
    if bytes.len() as u64 > MAX_WALLPAPER_BYTES || !is_picture(&bytes) {
        tracing::warn!("the Mac's wallpaper is not a JPEG or PNG");
        return None;
    }
    let id = Sha256::digest(&bytes).iter().map(|b| format!("{b:02x}")).collect::<String>();
    let info =
        WallpaperInfo { id, bytes: bytes.len() as u64, tint_opacity: unit(file.tint_opacity).unwrap_or(0.0) };
    Some((info, Bytes::from(bytes)))
}

/// None until the app sent its first appearance: a phone keeps its cached copy until then.
fn current_sender() -> &'static watch::Sender<Option<Current>> {
    static CURRENT: OnceLock<watch::Sender<Option<Current>>> = OnceLock::new();
    CURRENT.get_or_init(|| watch::channel(None).0)
}

/// Applies the app's line: a bad theme is ignored (the last good one stays); a wallpaper that
/// cannot be served is dropped (the phone shows the theme's plain background).
pub async fn set(from_app: FromApp) {
    // Each line reads its wallpaper on its own task: only the newest line may publish, so a
    // slow read of an older picture never lands over a newer one.
    static LATEST: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let turn = LATEST.fetch_add(1, std::sync::atomic::Ordering::SeqCst) + 1;
    let Some(theme) = sanitize(from_app.theme) else {
        tracing::warn!("ignoring an unusable appearance from the app");
        return;
    };
    let wallpaper = match &from_app.wallpaper {
        Some(file) => read_wallpaper(file).await,
        None => None,
    };
    let terminal = from_app.terminal.and_then(sanitize_terminal);
    let look = from_app.look.as_ref().and_then(sanitize_look);
    if LATEST.load(std::sync::atomic::Ordering::SeqCst) != turn {
        return;
    }
    publish(Current { theme, wallpaper, terminal, look });
}

/// Publishes `current`; phones hear it only when it changed.
pub fn publish(current: Current) {
    current_sender().send_if_modified(|now| {
        if now.as_ref() == Some(&current) {
            return false;
        }
        *now = Some(current);
        true
    });
}

/// The appearance now and as it changes (None: not known yet).
pub fn subscribe() -> watch::Receiver<Option<Current>> {
    current_sender().subscribe()
}

/// The `appearance` service: the message now and on each change, until the phone closes it.
pub async fn serve(sender: &ChannelSender, mut receiver: ChannelReceiver) -> Result<(), Refusal> {
    let mut current = subscribe();
    loop {
        let message = current.borrow_and_update().as_ref().map(Current::message);
        // Not known yet: nothing is sent until the app's first appearance arrives.
        if let Some(message) = message
            && sender.send(Bytes::from(message.to_string())).await.is_err()
        {
            return Ok(());
        }
        loop {
            tokio::select! {
                changed = current.changed() => {
                    if changed.is_err() {
                        return Ok(());
                    }
                    break;
                }
                event = receiver.recv() => match event {
                    Some(ChannelEvent::Data(_)) => {}
                    Some(ChannelEvent::Closed(_)) | None => return Ok(()),
                },
            }
        }
    }
}

/// The bytes of wallpaper `id` when it is the current one.
pub fn wallpaper_bytes(current: Option<&Current>, id: &str) -> Result<Bytes, Refusal> {
    match current.and_then(|c| c.wallpaper.as_ref()) {
        Some((info, bytes)) if info.id == id => Ok(bytes.clone()),
        Some(_) => Err(Refusal::new("stale", "the Mac shows another wallpaper now")),
        None => Err(Refusal::new("not_found", "the Mac shows no wallpaper")),
    }
}

/// The `appearance-wallpaper` service: `{"id"}` streams that wallpaper's bytes, then `eof`.
pub async fn serve_wallpaper(sender: &ChannelSender, args: &Value) -> Result<(), Refusal> {
    let id =
        args.get("id").and_then(Value::as_str).ok_or_else(|| Refusal::new("bad_request", "missing id"))?;
    let bytes = wallpaper_bytes(subscribe().borrow().as_ref(), id)?;
    for chunk in bytes.chunks(WALLPAPER_CHUNK) {
        if sender.send(bytes.slice_ref(chunk)).await.is_err() {
            return Ok(());
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn theme() -> Theme {
        Theme {
            background: "#1E1E2E".into(),
            foreground: "#cdd6f4".into(),
            palette: (0..16).map(|n| format!("#{n:02x}{n:02x}{n:02x}")).collect(),
            selection_background: Some("#585b70".into()),
            selection_foreground: None,
            cursor: Some("bogus".into()),
            accent: "magenta".into(),
            accent_color: None,
            background_opacity: 0.9,
        }
    }

    #[test]
    fn sanitize_keeps_a_good_theme_and_normalizes_it() {
        let clean = sanitize(theme()).unwrap();
        assert_eq!(clean.background, "#1e1e2e");
        assert_eq!(clean.palette.len(), 16);
        assert_eq!(clean.selection_background.as_deref(), Some("#585b70"));
        // A malformed optional color is dropped, not the theme.
        assert_eq!(clean.cursor, None);
        assert_eq!(clean.accent, "magenta");
    }

    #[test]
    fn sanitize_refuses_what_the_phone_cannot_derive_from() {
        let mut bad = theme();
        bad.background = "red".into();
        assert!(sanitize(bad).is_none());
        let mut short = theme();
        short.palette.truncate(5);
        assert!(sanitize(short).is_none());
        let mut long = theme();
        long.palette.extend((0..240).map(|_| "#000000".to_owned()));
        assert_eq!(sanitize(long).unwrap().palette.len(), 16);
        let mut odd = theme();
        odd.accent = "chartreuse".into();
        assert_eq!(sanitize(odd).unwrap().accent, "neutral");
        let mut over = theme();
        over.background_opacity = 4.0;
        assert_eq!(sanitize(over).unwrap().background_opacity, 1.0);
    }

    #[test]
    fn the_control_line_parses_with_defaults() {
        let line = r##"{"theme":{"background":"#000000","foreground":"#ffffff","palette":["#000000","#111111","#222222","#333333","#444444","#555555","#666666","#777777"]},"wallpaper":{"path":"/tmp/w.jpg","tint_opacity":0.6}}"##;
        let parsed: FromApp = serde_json::from_str(line).unwrap();
        assert_eq!(parsed.theme.accent, "neutral");
        assert_eq!(parsed.theme.background_opacity, 1.0);
        assert_eq!(parsed.wallpaper.unwrap().tint_opacity, 0.6);
    }

    #[tokio::test]
    async fn a_wallpaper_is_read_once_named_by_content_and_bounded() {
        let dir = tempfile::tempdir().unwrap();
        let jpeg = dir.path().join("w.jpg");
        let mut bytes = vec![0xFF, 0xD8, 0xFF, 0xE0];
        bytes.extend(std::iter::repeat_n(7u8, 200_000));
        std::fs::write(&jpeg, &bytes).unwrap();
        let file = WallpaperFile { path: jpeg.to_string_lossy().into_owned(), tint_opacity: 0.62 };
        let (info, served) = read_wallpaper(&file).await.unwrap();
        assert_eq!(info.bytes, bytes.len() as u64);
        assert_eq!(info.id.len(), 64);
        assert_eq!(served.as_ref(), bytes.as_slice());
        // Not a picture, a relative path, or a missing file: nothing is served.
        let text = dir.path().join("w.txt");
        std::fs::write(&text, b"hello").unwrap();
        assert!(
            read_wallpaper(&WallpaperFile { path: text.to_string_lossy().into_owned(), tint_opacity: 0.0 })
                .await
                .is_none()
        );
        assert!(read_wallpaper(&WallpaperFile { path: "w.jpg".into(), tint_opacity: 0.0 }).await.is_none());
        assert!(
            read_wallpaper(&WallpaperFile { path: "/nonexistent/w.jpg".into(), tint_opacity: 0.0 })
                .await
                .is_none()
        );
    }

    #[test]
    fn only_the_current_wallpaper_is_served() {
        let info = WallpaperInfo { id: "abc".into(), bytes: 3, tint_opacity: 0.5 };
        let current = Current {
            theme: sanitize(theme()).unwrap(),
            wallpaper: Some((info, Bytes::from_static(b"\xFF\xD8\xFF"))),
            terminal: None,
            look: None,
        };
        assert_eq!(wallpaper_bytes(Some(&current), "abc").unwrap().as_ref(), b"\xFF\xD8\xFF");
        assert_eq!(wallpaper_bytes(Some(&current), "old").unwrap_err().code, "stale");
        assert_eq!(wallpaper_bytes(None, "abc").unwrap_err().code, "not_found");
        let message = current.message();
        assert_eq!(message["wallpaper"]["id"], "abc");
        assert_eq!(message["theme"]["background"], "#1e1e2e");
        // The path the app wrote never reaches a phone.
        assert!(!message.to_string().contains("path"));
    }

    #[tokio::test]
    async fn phones_hear_an_appearance_only_when_it_changes() {
        let mut current = subscribe();
        let first =
            Current { theme: sanitize(theme()).unwrap(), wallpaper: None, terminal: None, look: None };
        publish(first.clone());
        assert!(current.has_changed().unwrap());
        current.mark_unchanged();
        publish(first);
        assert!(!current.has_changed().unwrap());
        // A bad theme from the app leaves the last good one in place.
        let mut bad = theme();
        bad.foreground = "#12".into();
        set(FromApp { theme: bad, wallpaper: None, terminal: None, look: None }).await;
        assert!(!current.has_changed().unwrap());
        assert_eq!(current.borrow().as_ref().unwrap().theme.background, "#1e1e2e");
    }

    #[test]
    fn terminal_lines_keep_only_the_theme_keys_with_plain_values() {
        let lines: Vec<String> = [
            "background = #2B0B3F",
            "foreground = #f9e79f",
            "palette = 0=#3d1458",
            "palette = 255=#eeeeee",
            "cursor-color = cell-foreground",
            "cursor-text =",
            "bold-color = bright",
            "minimum-contrast = 1.2",
            "palette-generate = true",
            "window-colorspace = display-p3",
            // Not a theme key: a phone never runs the Mac's command or loads its files.
            "command = /bin/sh -c 'curl x'",
            "config-file = /etc/passwd",
            "keybind = cmd+k=text:rm -rf ~",
            // A theme key with a value Ghostty would read as something else.
            "background = #000000\nkeybind = a=text:x",
            "foreground = $(whoami)",
            "no equals sign",
        ]
        .iter()
        .map(|s| s.to_string())
        .collect();
        let kept = sanitize_terminal(lines).unwrap();
        assert_eq!(
            kept,
            vec![
                "background = #2B0B3F",
                "foreground = #f9e79f",
                "palette = 0=#3d1458",
                "palette = 255=#eeeeee",
                "cursor-color = cell-foreground",
                "cursor-text =",
                "bold-color = bright",
                "minimum-contrast = 1.2",
                "palette-generate = true",
                "window-colorspace = display-p3",
            ]
        );
    }

    #[test]
    fn terminal_lines_need_a_background_and_a_foreground_and_are_bounded() {
        assert!(sanitize_terminal(vec!["palette = 0=#000000".into()]).is_none());
        let mut many: Vec<String> = vec!["background = #000000".into(), "foreground = #ffffff".into()];
        many.extend((0..1000).map(|n| format!("palette = {}=#000000", n % 256)));
        assert_eq!(sanitize_terminal(many).unwrap().len(), MAX_TERMINAL_LINES);
        let long = format!("background = #{}", "a".repeat(MAX_TERMINAL_VALUE + 1));
        assert!(sanitize_terminal(vec![long, "foreground = #ffffff".into()]).is_none());
    }

    #[test]
    fn the_terminal_theme_rides_the_appearance_message() {
        let line = r##"{"theme":{"background":"#000000","foreground":"#ffffff","palette":["#000000","#111111","#222222","#333333","#444444","#555555","#666666","#777777"]},"terminal":["background = #2b0b3f","foreground = #f9e79f","command = x"]}"##;
        let parsed: FromApp = serde_json::from_str(line).unwrap();
        let terminal = parsed.terminal.and_then(sanitize_terminal);
        let current =
            Current { theme: sanitize(parsed.theme).unwrap(), wallpaper: None, terminal, look: None };
        let message = current.message();
        assert_eq!(message["terminal"], serde_json::json!(["background = #2b0b3f", "foreground = #f9e79f"]));
        // An app that sends no terminal theme: the message has no `terminal` key.
        let older = Current { terminal: None, ..current };
        assert!(older.message().get("terminal").is_none());
    }

    const LINE_HEAD: &str = r##"{"theme":{"background":"#000000","foreground":"#ffffff","palette":["#000000","#111111","#222222","#333333","#444444","#555555","#666666","#777777"]}"##;

    fn current_of(line: &str) -> Current {
        let parsed: FromApp = serde_json::from_str(line).unwrap();
        let look = parsed.look.as_ref().and_then(sanitize_look);
        Current { theme: sanitize(parsed.theme).unwrap(), wallpaper: None, terminal: None, look }
    }

    #[test]
    fn appearance_look_fields_are_served_as_the_app_sent_them() {
        let line = format!(
            r##"{LINE_HEAD},"look":{{"chrome_style":"two-tone","hue":0.25,"saturation":1.5,"glass_transparency":0.4,"sidebar_surface":"separate","terminal_font":{{"family":" JetBrains Mono ","size":13}},"chat":{{"sent":"#0A84FF","sent_text":"#ffffff","received":"#3a3a3c","received_text":"#FFFFFF"}},"groups":{{"palette":"gradient","gradient":"twoTone"}}}}}}"##
        );
        let message = current_of(&line).message();
        assert_eq!(
            message["look"],
            serde_json::json!({
                "chrome_style": "two-tone",
                "hue": 0.25,
                "saturation": 1.5,
                "glass_transparency": 0.4,
                "sidebar_surface": "separate",
                "terminal_font": {"family": "JetBrains Mono", "size": 13.0},
                "chat": {"sent": "#0a84ff", "sent_text": "#ffffff", "received": "#3a3a3c", "received_text": "#ffffff"},
                "groups": {"palette": "gradient", "gradient": "twoTone"},
            })
        );
        // Every bound is inclusive.
        let edges = serde_json::json!({"hue": 1.0, "saturation": 0.0, "glass_transparency": 1.0,
            "terminal_font": {"size": 96}});
        let edges = sanitize_look(&edges).unwrap();
        assert_eq!(
            (edges.hue, edges.saturation, edges.glass_transparency),
            (Some(1.0), Some(0.0), Some(1.0))
        );
        assert_eq!(edges.terminal_font.unwrap().size, Some(96.0));
    }

    #[test]
    fn appearance_look_drops_each_invalid_field_alone() {
        let line = format!(
            r##"{LINE_HEAD},"look":{{"chrome_style":"chartreuse","hue":1.5,"saturation":"1","glass_transparency":-0.1,"sidebar_surface":"separate","terminal_font":{{"family":"Evil\nfont-family = x","size":200}},"chat":{{"sent":"blue","sent_text":"#12345","received":"#1a2b3c80","received_text":"#a1b2c3"}},"groups":{{"palette":"rainbow","gradient":"aurora"}}}}}}"##
        );
        let current = current_of(&line);
        // The theme still serves.
        assert_eq!(current.theme.background, "#000000");
        let message = current.message();
        assert_eq!(
            message["look"],
            serde_json::json!({
                "sidebar_surface": "separate",
                "chat": {"received_text": "#a1b2c3"},
                "groups": {"gradient": "aurora"},
            })
        );
        // A family with a quote, a hash or an equals sign, an empty one, or one too long.
        for family in ["Mono\"", "Mono #1", "a=b", "   ", "m".repeat(MAX_FONT_FAMILY + 1).as_str()] {
            assert!(
                sanitize_look(&serde_json::json!({"terminal_font": {"family": family}})).is_none(),
                "{family}"
            );
        }
        assert!(sanitize_look(&serde_json::json!({"terminal_font": {"size": 3.9}})).is_none());
        // Nothing valid at all, or not an object: no `look`.
        assert!(sanitize_look(&serde_json::json!({"chrome_style": 3, "chat": {"sent": "red"}})).is_none());
        assert!(sanitize_look(&serde_json::json!("two-tone")).is_none());
        let none_valid = current_of(&format!(r##"{LINE_HEAD},"look":{{"hue":"x"}}}}"##));
        assert!(none_valid.message().get("look").is_none());
    }

    #[test]
    fn appearance_without_look_is_the_message_from_before_it() {
        let older = current_of(&format!("{LINE_HEAD}}}"));
        assert_eq!(older.look, None);
        // What `message` built before `look` existed, byte for byte.
        let before = serde_json::json!({"theme": older.theme, "wallpaper": Option::<WallpaperInfo>::None});
        assert_eq!(older.message().to_string(), before.to_string());
        assert_eq!(
            older.message().to_string(),
            r##"{"theme":{"accent":"neutral","background":"#000000","background_opacity":1.0,"foreground":"#ffffff","palette":["#000000","#111111","#222222","#333333","#444444","#555555","#666666","#777777"]},"wallpaper":null}"##
        );
        // An empty `look` from the app is the same message.
        let empty = current_of(&format!(r##"{LINE_HEAD},"look":{{}}}}"##));
        assert_eq!(empty.message().to_string(), before.to_string());
    }
}
