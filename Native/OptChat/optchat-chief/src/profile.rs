//! The Chief's avatar in `$MUX_HOME/optchat/profile.json` (`{"avatar": ...}`),
//! beside engine.json: a short text (an emoji or two letters) the Mac's Chief
//! header and a phone's chat header show, or the file name of a picture beside
//! it (`cat.png`), which only the Mac sets and shows. `chief.engine.get`
//! reports the text (null for a picture or none); `chief.engine.set {avatar}`
//! writes a text, or clears it with an empty string. Other keys in the file
//! are kept.

use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};

use serde_json::{Map, Value};

/// The longest avatar text, in Unicode scalars: room for one emoji made of
/// several (a family, a flag with a modifier) or two letters.
pub const MAX_AVATAR_CHARS: usize = 16;

/// `profile.json` beside `engine_file` (`optchat/engine.json`).
pub fn path_beside(engine_file: &Path) -> PathBuf {
    engine_file.with_file_name("profile.json")
}

fn read_object(file: &Path) -> Map<String, Value> {
    std::fs::read(file)
        .ok()
        .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
        .and_then(|value| match value {
            Value::Object(object) => Some(object),
            _ => None,
        })
        .unwrap_or_default()
}

/// Whether `value` names a picture rather than text: a file name (no path)
/// with an image extension, as the Mac reads it (`HomeChiefFiles.namesPicture`).
pub fn names_picture(value: &str) -> bool {
    let extension = Path::new(value)
        .extension()
        .and_then(|e| e.to_str())
        .map(str::to_ascii_lowercase);
    !value.contains('/') && matches!(extension.as_deref(), Some("png" | "jpg" | "jpeg" | "heic"))
}

/// The avatar text; None when the profile sets none or names a picture.
pub fn avatar_text(file: &Path) -> Option<String> {
    read_object(file)
        .get("avatar")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|a| !a.is_empty() && !names_picture(a))
        .map(str::to_owned)
}

/// A text a person may set: trimmed, at most [`MAX_AVATAR_CHARS`], no
/// control characters, and not a picture's file name. Empty clears.
pub fn check_avatar(value: &str) -> Result<String, String> {
    let value = value.trim();
    if value.chars().count() > MAX_AVATAR_CHARS {
        return Err(format!(
            "avatar is at most {MAX_AVATAR_CHARS} characters (an emoji or two letters)"
        ));
    }
    if value.chars().any(char::is_control) {
        return Err("avatar has a control character".to_owned());
    }
    if names_picture(value) {
        return Err("avatar is text; a picture is chosen on the Mac".to_owned());
    }
    Ok(value.to_owned())
}

/// Sets (or, for "", removes) `avatar`, keeping the file's other keys:
/// through a temporary file (0600) and a rename, as engine.json.
pub fn save_avatar(file: &Path, avatar: &str) -> std::io::Result<()> {
    let mut object = read_object(file);
    if avatar.is_empty() {
        object.remove("avatar");
    } else {
        object.insert("avatar".to_owned(), Value::String(avatar.to_owned()));
    }
    if let Some(dir) = file.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let tmp = file.with_extension(format!("json.{}.tmp", std::process::id()));
    let mut out = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&tmp)?;
    let mut bytes =
        serde_json::to_vec_pretty(&Value::Object(object)).map_err(std::io::Error::other)?;
    bytes.push(b'\n');
    out.write_all(&bytes)?;
    out.sync_all()?;
    std::fs::rename(&tmp, file)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_picture_reads_as_no_text_and_cannot_be_set() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("profile.json");
        assert_eq!(avatar_text(&file), None);
        std::fs::write(&file, r#"{"avatar": "cat.PNG", "other": 1}"#).unwrap();
        assert_eq!(avatar_text(&file), None);
        assert!(check_avatar("cat.png").is_err());
        assert!(check_avatar("a/b").is_ok());
    }

    #[test]
    fn setting_and_clearing_keeps_the_other_keys() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("profile.json");
        std::fs::write(&file, r#"{"avatar": "cat.png", "other": 1}"#).unwrap();
        save_avatar(&file, "🦊").unwrap();
        assert_eq!(avatar_text(&file).as_deref(), Some("🦊"));
        save_avatar(&file, "").unwrap();
        assert_eq!(avatar_text(&file), None);
        let kept: Value = serde_json::from_slice(&std::fs::read(&file).unwrap()).unwrap();
        assert_eq!(kept, serde_json::json!({"other": 1}));
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            std::fs::metadata(&file).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }

    #[test]
    fn checks_length_and_controls() {
        assert_eq!(check_avatar("  AB ").unwrap(), "AB");
        assert_eq!(check_avatar("").unwrap(), "");
        assert!(check_avatar("x\ny").is_err());
        assert!(check_avatar(&"a".repeat(MAX_AVATAR_CHARS + 1)).is_err());
        assert!(check_avatar("👨‍👩‍👧‍👦").is_ok());
    }
}
