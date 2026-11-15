//! Whether this Chief host may send analytics, re-read every few minutes so
//! turning telemetry off stops sending at once and deletes what waits.
//!
//! The rule is the cmux CLI's crash forwarding (`cmux-tui`
//! `owner_start/crash_forward.rs`, docs/privacy.md "Telemetry"), with one
//! Chief switch added:
//!
//! 1. a managed profile's `DisableTelemetry` (or a forced
//!    `app.sendAnonymousTelemetry: false`): off;
//! 2. `DO_NOT_TRACK` set (and not `0`/`false`): off;
//! 3. `CMUX_CHIEF_ANALYTICS` = `0`/`off`/`false`/`no`: off. The app sets it
//!    to `off` when its own `sendAnonymousTelemetry` choice is off;
//! 4. `app.sendAnonymousTelemetry: false` in the cmux settings file: off;
//! 5. `CI` set: off;
//! 6. a build that is not a release (a debug compile, a DEV or tagged app):
//!    off unless `CMUX_CHIEF_ANALYTICS=dev`, which sends with
//!    `environment: dev` (the staging route: same project, filtered out of
//!    every dashboard).

use serde_json::Value;

/// The decision, with why when it is off (host.log says it once).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Consent {
    /// Send, labeled with this environment (`production` or `dev`).
    Send(&'static str),
    Off(&'static str),
}

/// Everything the rule reads, injected so tests need no environment.
pub struct Inputs<'a> {
    pub managed_forced: &'a std::collections::BTreeMap<String, Value>,
    pub settings: Option<&'a Value>,
    /// A release build: not `debug_assertions`, and not a DEV or tagged app.
    pub release_build: bool,
    pub env: &'a dyn Fn(&str) -> Option<String>,
}

fn falsy(value: &str) -> bool {
    matches!(
        value.trim().to_ascii_lowercase().as_str(),
        "0" | "off" | "false" | "no"
    )
}

pub fn decide(inputs: &Inputs<'_>) -> Consent {
    let env = |name: &str| (inputs.env)(name).filter(|v| !v.trim().is_empty());
    if inputs.managed_forced.get("DisableTelemetry") == Some(&Value::Bool(true))
        || inputs.managed_forced.get("app.sendAnonymousTelemetry") == Some(&Value::Bool(false))
    {
        return Consent::Off("managed policy DisableTelemetry");
    }
    if env("DO_NOT_TRACK").is_some_and(|v| !falsy(&v)) {
        return Consent::Off("DO_NOT_TRACK");
    }
    let chief = env("CMUX_CHIEF_ANALYTICS");
    if chief.as_deref().is_some_and(falsy) {
        return Consent::Off("CMUX_CHIEF_ANALYTICS=off");
    }
    let setting = inputs.settings.and_then(|root| {
        cmux_config::value::value_at(root, &["app", "sendAnonymousTelemetry"][..])
    });
    if setting == Some(&Value::Bool(false)) {
        return Consent::Off("app.sendAnonymousTelemetry is false");
    }
    if env("CI").is_some() {
        return Consent::Off("CI");
    }
    let dev = chief.as_deref().map(str::trim) == Some("dev");
    if dev {
        return Consent::Send("dev");
    }
    if !inputs.release_build {
        return Consent::Off("not a release build");
    }
    Consent::Send("production")
}

/// The decision now, from this process's environment, the managed
/// preferences and the settings file.
pub fn read(release_build: bool) -> Consent {
    let env = |name: &str| std::env::var(name).ok();
    let managed = cmux_config::managed::default_reader(env).read();
    let settings = std::fs::read_to_string(cmux_config::config_path())
        .ok()
        .and_then(|text| cmux_config::jsonc::parse(&text).ok());
    decide(&Inputs {
        managed_forced: &managed.forced,
        settings: settings.as_ref(),
        release_build,
        env: &env,
    })
}
