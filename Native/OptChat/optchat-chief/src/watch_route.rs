//! How the host runs a Chief `watch` command when glaeda-gh is on the host.

/// What the host runs for a watch.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Route {
    /// The command as the Chief gave it.
    Keep,
    /// This command and `until` instead.
    Rewrite {
        command: String,
        until: Option<String>,
    },
    /// Not started: it would poll GitHub; the text says what to run instead.
    Refuse(String),
}

/// How the host runs `command` with `until` for `timeout_seconds`.
pub fn route(_command: &str, _until: Option<&str>, _timeout_seconds: u64) -> Route {
    Route::Keep
}
