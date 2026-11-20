//! Which app a name names: an absolute path, an id, then a name, in that order.

use super::{App, Refusal};
use std::path::Path;

/// The cmux build device setup installs and keeps running (`devices/setup/scripts.rs`).
const NIGHTLY: &str = "cmux nightly";

/// The app `query` names among `apps` (this machine's, in search order: the first of two of one
/// name wins, as /Applications comes before ~/Applications). `cmux` names the cmux app this
/// daemon came from, `own`, else NIGHTLY. An absolute path need not be listed: it is opened as
/// it is, if it is there.
pub fn resolve(query: &str, apps: &[App], own: Option<&Path>) -> Result<App, Refusal> {
    let query = query.trim();
    let path = Path::new(query);
    if path.is_absolute() {
        if let Some(app) = apps.iter().find(|app| app.path == path) {
            return Ok(app.clone());
        }
        if !path.exists() {
            return Err(Refusal::NotFound(query.to_owned()));
        }
        return Ok(App {
            name: path
                .file_stem()
                .map_or_else(|| query.to_owned(), |s| s.to_string_lossy().into_owned()),
            id: None,
            exe: path.is_file().then(|| path.to_path_buf()),
            path: path.to_path_buf(),
        });
    }
    let lower = query.to_lowercase();
    let named = |app: &&App, name: &str| app.name.to_lowercase() == name || stem(app) == name;
    if lower == "cmux" {
        let own = own.and_then(|own| apps.iter().find(|app| app.path == own));
        if let Some(app) = own.or_else(|| apps.iter().find(|app| named(app, NIGHTLY))) {
            return Ok(app.clone());
        }
    }
    let by_id =
        apps.iter().find(|app| app.id.as_deref().is_some_and(|id| id.to_lowercase() == lower));
    by_id
        .or_else(|| apps.iter().find(|app| named(app, &lower)))
        .cloned()
        .ok_or_else(|| Refusal::NotFound(query.to_owned()))
}

/// The app's file name without `.app` or `.desktop`, lower case.
fn stem(app: &App) -> String {
    let name = app.path.file_name().map(|n| n.to_string_lossy().to_lowercase()).unwrap_or_default();
    name.strip_suffix(".app")
        .or_else(|| name.strip_suffix(".desktop"))
        .map_or_else(|| name.clone(), str::to_owned)
}
