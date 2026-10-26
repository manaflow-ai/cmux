//! The Chief's panic log: one JSON line per panic in
//! `$MUX_HOME/optchat/panics.jsonl` (the `cmux-panic-log` format), which the
//! cmux-next app sends to Sentry under the user's telemetry choice. Stderr
//! goes to `host.log`, where no one reads a panic; the previous hook still
//! writes it there.
//!
//! The log lives in the owner-only `optchat/` folder ([`Paths::create`]).
//! A verb run before the first host start has no such folder, so its panic
//! is not logged rather than written somewhere less private.
//!
//! [`Paths::create`]: crate::paths::Paths::create

use std::path::{Path, PathBuf};

/// `<home>/optchat/panics.jsonl`.
pub fn log_path(home: &Path) -> PathBuf {
    crate::paths::Paths::new(home).root.join("panics.jsonl")
}

/// The fields every line of this process carries; `main` installs the hook
/// with them. `verb` is the first word of the command line (`host`, `mcp`,
/// ...), so a report says which run panicked.
pub fn fields(verb: &str) -> cmux_panic_log::Fields {
    let mut fields = cmux_panic_log::Fields::new();
    fields.insert("process".into(), "optchat-chief".into());
    fields.insert("verb".into(), verb.into());
    fields.insert("pid".into(), std::process::id().into());
    fields.insert("version".into(), env!("CARGO_PKG_VERSION").into());
    fields.insert("os".into(), std::env::consts::OS.into());
    fields.insert("arch".into(), std::env::consts::ARCH.into());
    fields
}
