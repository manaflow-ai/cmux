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
}

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
}

impl Current {
    /// The `appearance` message.
    pub fn message(&self) -> Value {
        serde_json::json!({
            "theme": self.theme,
            "wallpaper": self.wallpaper.as_ref().map(|(info, _)| info),
        })
    }
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
    if LATEST.load(std::sync::atomic::Ordering::SeqCst) != turn {
        return;
    }
    publish(Current { theme, wallpaper });
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
        let first = Current { theme: sanitize(theme()).unwrap(), wallpaper: None };
        publish(first.clone());
        assert!(current.has_changed().unwrap());
        current.mark_unchanged();
        publish(first);
        assert!(!current.has_changed().unwrap());
        // A bad theme from the app leaves the last good one in place.
        let mut bad = theme();
        bad.foreground = "#12".into();
        set(FromApp { theme: bad, wallpaper: None }).await;
        assert!(!current.has_changed().unwrap());
        assert_eq!(current.borrow().as_ref().unwrap().theme.background, "#1e1e2e");
    }
}
