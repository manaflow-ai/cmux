//! The sidecar's panic log: one JSON line per panic in
//! `<root>/.sidecar-panics.jsonl` (the `cmux-panic-log` format), which the
//! cmux-next app sends to Sentry under the user's telemetry choice. The
//! app reads the child's stderr only for its ready marker, so a panic
//! message there is lost; the previous hook still writes it.
//!
//! `main` installs it once the root has passed its owner and 0700
//! check, so the log never lands in a folder another user can read.

use std::path::{Path, PathBuf};

/// The log's file name inside the diff root.
pub const LOG_NAME: &str = ".sidecar-panics.jsonl";

/// `<root>/.sidecar-panics.jsonl`.
#[must_use]
pub fn log_path(root: &Path) -> PathBuf {
    root.join(LOG_NAME)
}

/// The fields every line of this process carries; `main` installs the hook
/// with them. `mode` is the subcommand (`rpc`, `serve`), so a report says
/// which run panicked.
#[must_use]
pub fn fields(mode: &str) -> cmux_panic_log::Fields {
    let mut fields = cmux_panic_log::Fields::new();
    fields.insert("process".into(), "cmux-diff-sidecar".into());
    fields.insert("mode".into(), mode.into());
    fields.insert("pid".into(), std::process::id().into());
    fields.insert("version".into(), env!("CARGO_PKG_VERSION").into());
    fields.insert("os".into(), std::env::consts::OS.into());
    fields.insert("arch".into(), std::env::consts::ARCH.into());
    fields
}
