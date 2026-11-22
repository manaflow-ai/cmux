//! A harness's icon (user 12922): what a profile's `icon` key may say, and the
//! one icon every client draws for a harness (`iconSpec` in `_acpmux/harnesses`).
//!
//! A profile's `icon` is one of:
//! - an agent mark id from design/agent-icons (`claude`, `goose`, `gemini`, ...),
//!   or a built-in glyph (`terminal`, `generic`);
//! - one emoji (`🦊`);
//! - an SF Symbol name (`hammer.fill`, `sparkles`; `sf:NAME` forces one);
//! - an `.svg` or `.png` file next to the profile (at most [`MAX_ICON_BYTES`]).
//!
//! When the key is absent (or names a file that is missing or too large) the
//! daemon picks one: the mark of the agent the harness runs, read from its id,
//! its command (through a package runner such as `npx -y @google/gemini-cli`)
//! or its family; else a monogram of its name in a hue stable for its id.
//! Clients never guess: they draw the `iconSpec`.

use std::path::Path;

use base64::Engine as _;
use serde::Serialize;

use super::HarnessProfile;

/// Largest icon file accepted, in bytes. The image travels inline (base64) in
/// every `_acpmux/harnesses` reply, so it is kept small.
pub const MAX_ICON_BYTES: u64 = 256 * 1024;
/// Built-in glyphs a profile may name that are no agent mark.
pub const GLYPHS: &[&str] = &["terminal", "generic"];
/// Longest emoji accepted, in UTF-8 bytes (the app's `IconValue` limit).
const MAX_EMOJI_BYTES: usize = 32;
/// Longest SF Symbol name accepted, in bytes (the app's `IconValue` limit).
const MAX_SYMBOL_BYTES: usize = 128;

/// What a profile's `icon` value is, before any file is read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum IconValue {
    /// An agent, alias or mark id the design/agent-icons table knows.
    Brand(String),
    /// `terminal` or `generic`.
    Glyph(String),
    Emoji(String),
    /// An SF Symbol name.
    Symbol(String),
    /// A file name (or path) of an `.svg` or `.png`.
    File(String),
}

impl IconValue {
    /// Classifies `raw`, or says which forms an icon takes.
    pub fn parse(raw: &str) -> Result<Self, String> {
        let value = raw.trim();
        if value.is_empty() {
            return Err("the icon is empty".into());
        }
        if let Some(name) = value.strip_prefix("sf:") {
            return if is_symbol_name(name) {
                Ok(Self::Symbol(name.to_owned()))
            } else {
                Err(format!("{name:?} is not an SF Symbol name (lowercase words joined by dots)"))
            };
        }
        let lower = value.to_ascii_lowercase();
        if lower.ends_with(".svg") || lower.ends_with(".png") || value.contains('/') {
            return Ok(Self::File(value.to_owned()));
        }
        if GLYPHS.contains(&value) {
            return Ok(Self::Glyph(value.to_owned()));
        }
        if exact_brand(value).is_some() {
            return Ok(Self::Brand(value.to_lowercase()));
        }
        if is_emoji(value) {
            return Ok(Self::Emoji(value.to_owned()));
        }
        if is_symbol_name(value) {
            return Ok(Self::Symbol(value.to_owned()));
        }
        Err(format!(
            "{value:?} is not an icon: give one emoji, an SF Symbol name (hammer.fill), an agent \
             mark ({}) or an .svg/.png file",
            brand_examples()
        ))
    }

    /// The value as the profile file stores it.
    pub fn wire(&self) -> String {
        match self {
            Self::Brand(v) | Self::Glyph(v) | Self::Emoji(v) | Self::Symbol(v) | Self::File(v) => {
                v.clone()
            }
        }
    }
}

/// The icon clients draw for one harness.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum IconSpec {
    Brand {
        brand: String,
        source: IconSource,
    },
    Glyph {
        name: String,
        source: IconSource,
    },
    Emoji {
        text: String,
        source: IconSource,
    },
    /// An SF Symbol; `text` and `hue` are the monogram a client that cannot
    /// draw the symbol (a page without the host's symbol images, an older
    /// macOS without the name) shows instead.
    Symbol {
        name: String,
        text: String,
        hue: u16,
        source: IconSource,
    },
    /// The file's bytes, base64, so a page draws it with no file access.
    Image {
        mime: String,
        data: String,
        source: IconSource,
    },
    /// One or two letters on a disc of `hue` (0-359); clients pick the
    /// lightness for their theme.
    Monogram {
        text: String,
        hue: u16,
        source: IconSource,
    },
}

/// Where an [`IconSpec`] came from, so Settings can say "Automatic".
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum IconSource {
    /// The profile's `icon` key.
    Profile,
    /// The harness id names an agent.
    Id,
    /// The program it runs names an agent.
    Command,
    /// Its family names an agent.
    Family,
    /// Nothing named one: a monogram.
    Default,
}

/// A profile icon read at load time: the declared value, and for a file its
/// mime type and base64 bytes.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct LoadedIcon {
    pub value: Option<IconValue>,
    pub image: Option<(String, String)>,
}

/// Reads the file `icon` names next to `profile`: `(absolute path, mime, base64)`.
pub fn read_icon_file(profile: &Path, icon: &str) -> Result<(String, String, String), String> {
    let dir = profile.parent().unwrap_or(Path::new("."));
    let path = dir.join(icon);
    let ext = path.extension().map(|x| x.to_string_lossy().to_lowercase()).unwrap_or_default();
    let mime = match ext.as_str() {
        "svg" => "image/svg+xml",
        "png" => "image/png",
        _ => return Err(format!("icon {icon:?} must be an .svg or .png file")),
    };
    let meta = std::fs::metadata(&path).map_err(|_| format!("icon file {icon:?} is missing"))?;
    if !meta.is_file() || meta.len() > MAX_ICON_BYTES {
        return Err(format!("icon {icon:?} must be a file of at most {MAX_ICON_BYTES} bytes"));
    }
    let bytes = std::fs::read(&path).map_err(|e| format!("icon {icon:?}: {e}"))?;
    check_image_bytes(mime, &bytes).map_err(|why| format!("icon {icon:?}: {why}"))?;
    let data = base64::engine::general_purpose::STANDARD.encode(&bytes);
    Ok((path.to_string_lossy().into_owned(), mime.to_owned(), data))
}

/// The bytes are the image their extension says: a PNG signature, or an SVG
/// document (no script, no external reference: pages draw it as an image,
/// but the app's native views parse it too).
pub fn check_image_bytes(mime: &str, bytes: &[u8]) -> Result<(), String> {
    if mime == "image/png" {
        return if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
            Ok(())
        } else {
            Err("the file is not a PNG image".into())
        };
    }
    let text = std::str::from_utf8(bytes).map_err(|_| "the SVG is not UTF-8 text".to_owned())?;
    let lower = text.to_ascii_lowercase();
    if !lower.contains("<svg") {
        return Err("the file is not an SVG image".into());
    }
    for banned in ["<script", "javascript:", "<foreignobject", "onload=", "onerror="] {
        if lower.contains(banned) {
            return Err(format!("the SVG holds {banned:?}; icons may not run code"));
        }
    }
    Ok(())
}

/// The icon clients draw for harness `id`.
pub fn resolve(
    id: &str,
    display_name: Option<&str>,
    profile: &HarnessProfile,
    family: &str,
    declared: Option<&LoadedIcon>,
) -> IconSpec {
    let none = LoadedIcon::default();
    let declared = declared.unwrap_or(&none);
    match (&declared.value, &declared.image) {
        (Some(IconValue::File(_)), Some((mime, data))) => {
            return IconSpec::Image {
                mime: mime.clone(),
                data: data.clone(),
                source: IconSource::Profile,
            };
        }
        (Some(IconValue::Brand(named)), _) => {
            let brand = exact_brand(named).unwrap_or(named.as_str()).to_owned();
            return IconSpec::Brand { brand, source: IconSource::Profile };
        }
        (Some(IconValue::Glyph(name)), _) => {
            return IconSpec::Glyph { name: name.clone(), source: IconSource::Profile };
        }
        (Some(IconValue::Emoji(text)), _) => {
            return IconSpec::Emoji { text: text.clone(), source: IconSource::Profile };
        }
        (Some(IconValue::Symbol(name)), _) => {
            return IconSpec::Symbol {
                name: name.clone(),
                text: monogram(display_name.filter(|n| !n.trim().is_empty()).unwrap_or(id)),
                hue: hue(id),
                source: IconSource::Profile,
            };
        }
        // A missing or bad file: the profile's diagnostics say so; pick one.
        (Some(IconValue::File(_)), None) | (None, _) => {}
    }
    detected(id, display_name, profile, family)
}

/// The icon a harness gets with no `icon` key.
pub fn detected(
    id: &str,
    display_name: Option<&str>,
    profile: &HarnessProfile,
    family: &str,
) -> IconSpec {
    let brand = |b: &str| b.to_owned();
    // The Chief is the person's own agent, drawn as Home draws a Chief with no
    // picture: the CH monogram (its command, `cmux-tui`, would read as cmux's mark).
    if family == super::CHIEF_FAMILY {
        return IconSpec::Monogram { text: "CH".into(), hue: hue(id), source: IconSource::Family };
    }
    if let Some(b) = crate::chats::brand::brand_for(id) {
        return IconSpec::Brand { brand: brand(b), source: IconSource::Id };
    }
    if let Some(b) =
        program_names(&profile.argv).iter().find_map(|p| crate::chats::brand::brand_for(p))
    {
        return IconSpec::Brand { brand: brand(b), source: IconSource::Command };
    }
    if let Some(b) = crate::chats::brand::brand_for(family) {
        return IconSpec::Brand { brand: brand(b), source: IconSource::Family };
    }
    if profile.kind == super::HarnessKind::Terminal {
        return IconSpec::Glyph { name: "terminal".into(), source: IconSource::Default };
    }
    IconSpec::Monogram {
        text: monogram(display_name.filter(|n| !n.trim().is_empty()).unwrap_or(id)),
        hue: hue(id),
        source: IconSource::Default,
    }
}

/// Package runners: the agent is the package they run, not the runner.
const RUNNERS: &[&str] = &[
    "npx", "bunx", "pnpx", "uvx", "pipx", "pnpm", "yarn", "bun", "deno", "node", "python",
    "python3", "uv", "env", "nix", "mise", "asdf", "docker", "podman",
];
/// Runner words before the package (`pnpm dlx`, `pipx run`, `uv tool run`).
const RUNNER_VERBS: &[&str] = &["dlx", "exec", "run", "tool", "x", "shell"];

/// The names the argv runs, best first: the program, and through a package
/// runner the package (`@google/gemini-cli@0.9.0` -> `gemini-cli`).
pub fn program_names(argv: &[String]) -> Vec<String> {
    let base = |word: &str| {
        Path::new(word).file_name().map(|f| f.to_string_lossy().to_lowercase()).unwrap_or_default()
    };
    let Some(program) = argv.first() else { return Vec::new() };
    let program = base(program);
    if !RUNNERS.contains(&program.as_str()) {
        return vec![program];
    }
    // The first few words that are no flag: a flag's value (`--from x`) may
    // come first, so each is tried in turn.
    let mut out: Vec<String> = argv
        .iter()
        .skip(1)
        .filter(|w| !w.starts_with('-') && !w.contains('=') && !RUNNER_VERBS.contains(&w.as_str()))
        .take(3)
        .map(|w| package_name(w))
        .filter(|w| !w.is_empty())
        .collect();
    out.push(program);
    out
}

/// `@scope/name@1.2` -> `name`; `name==1.2` and `name@latest` -> `name`.
fn package_name(word: &str) -> String {
    let word = word.trim().to_lowercase();
    let unscoped = match word.strip_prefix('@') {
        Some(rest) => rest.split_once('/').map(|(_, n)| n.to_owned()).unwrap_or_default(),
        None => word.clone(),
    };
    let name = unscoped.split(['@', '=', '<', '>', '~', '[']).next().unwrap_or("");
    Path::new(name).file_name().map(|f| f.to_string_lossy().into_owned()).unwrap_or_default()
}

/// One or two capital letters for `name`: the first letters of its first two
/// words (`zeta-bot` -> `ZB`, `Acme Agent` -> `AA`), else its first letter.
pub fn monogram(name: &str) -> String {
    let words: Vec<&str> =
        name.split(|c: char| !c.is_alphanumeric()).filter(|w| !w.is_empty()).collect();
    let initial = |w: &str| w.chars().next().map(|c| c.to_uppercase().collect::<String>());
    match words.as_slice() {
        [] => "?".into(),
        [one] => initial(one).unwrap_or_default(),
        [first, second, ..] => {
            format!("{}{}", initial(first).unwrap_or_default(), initial(second).unwrap_or_default())
        }
    }
}

/// A hue (0-359) stable for `id`: FNV-1a, so every client and every run agree.
pub fn hue(id: &str) -> u16 {
    let mut h: u32 = 0x811c_9dc5;
    for b in id.bytes() {
        h ^= u32::from(b);
        h = h.wrapping_mul(0x0100_0193);
    }
    (h % 360) as u16
}

/// The mark of `value` when the whole value is a known agent, alias or
/// provider id (`goose`, `codex`, `claude-code`), not a word that only
/// contains one.
fn exact_brand(value: &str) -> Option<&'static str> {
    crate::chats::brand::exact(value)
}

fn brand_examples() -> &'static str {
    "claude, openai, gemini, goose, amp, ..."
}

/// An SF Symbol name: lowercase words of letters and digits joined by single dots.
pub fn is_symbol_name(text: &str) -> bool {
    !text.is_empty()
        && text.len() <= MAX_SYMBOL_BYTES
        && text.split('.').all(|w| {
            !w.is_empty() && w.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
        })
        && text.bytes().next().is_some_and(|b| b.is_ascii_lowercase())
}

/// One emoji: a short run of emoji scalars and their joiners and modifiers,
/// with no letter, digit or space (except a keycap's `0-9#*` base).
pub fn is_emoji(text: &str) -> bool {
    if text.is_empty() || text.len() > MAX_EMOJI_BYTES {
        return false;
    }
    let mut pictographs = 0;
    let mut joiners = 0;
    for (i, c) in text.chars().enumerate() {
        let u = c as u32;
        match u {
            0x200D => joiners += 1,
            0xFE0F | 0x20E3 | 0x1F3FB..=0x1F3FF | 0xE0020..=0xE007F => {}
            0x1F1E6..=0x1F1FF => pictographs += 1,
            0x30..=0x39 | 0x23 | 0x2A if i == 0 && text.contains('\u{20E3}') => pictographs += 1,
            0x1F000..=0x1FAFF
            | 0x2600..=0x27BF
            | 0x2300..=0x23FF
            | 0x2B00..=0x2BFF
            | 0x2190..=0x21FF
            | 0x3030
            | 0x303D
            | 0x3297
            | 0x3299
            | 0xA9
            | 0xAE
            | 0x203C
            | 0x2049
            | 0x2122
            | 0x2139
            | 0x24C2
            | 0x25AA..=0x25FE => pictographs += 1,
            _ => return false,
        }
    }
    // One grapheme: a single pictograph, a flag pair, or a ZWJ sequence.
    pictographs >= 1
        && (pictographs <= 1 + joiners || (pictographs == 2 && joiners == 0 && is_flag(text)))
}

fn is_flag(text: &str) -> bool {
    text.chars().all(|c| (0x1F1E6..=0x1F1FF).contains(&(c as u32)))
}

#[cfg(test)]
#[path = "harness_icon_tests.rs"]
mod tests;
