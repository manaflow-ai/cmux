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
//! 3. `CMUX_CHIEF_ANALYTICS` = `0`/`off`/`false`/`no`: off;
//!    the app's own `sendAnonymousTelemetry` choice off: off. The app passes
//!    its bundle id (`CMUX_CHIEF_APP_BUNDLE_ID`) and the host reads that
//!    domain's preference itself on every check, so an opt-out reaches a
//!    host that outlives the app;
//! 4. `app.sendAnonymousTelemetry: false` in the cmux settings file: off;
//! 5. `CI` set: off;
//! 6. `CMUX_CHIEF_ANALYTICS=dev`: sends with `environment: dev` (the
//!    staging route: same project, filtered out of every dashboard), a
//!    developer's own explicit switch;
//! 7. nobody turned it on: off. Analytics are opt-in: the app's own
//!    `sendAnonymousTelemetry` choice `true`, or, with no app choice (a CLI
//!    or Cloud host), `app.sendAnonymousTelemetry: true` in the settings
//!    file. A fresh install sends nothing (Leo, 2026-11-24: "whatever we
//!    do, we need to make sure it's opt out by defautl i assume?");
//! 8. a build that is not a release (a debug compile, a DEV or tagged app):
//!    off.

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
    /// The app's `sendAnonymousTelemetry` preference, when it is set.
    pub app_choice: Option<bool>,
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
    if inputs.app_choice == Some(false) {
        return Consent::Off("the app's sendAnonymousTelemetry is off");
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
    let opted_in = inputs
        .app_choice
        .unwrap_or(setting == Some(&Value::Bool(true)));
    if !opted_in {
        return Consent::Off("anonymous telemetry was never turned on");
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
    let app_choice = env("CMUX_CHIEF_APP_BUNDLE_ID")
        .filter(|id| valid_bundle_id(id))
        .and_then(|id| app_preference(&id, "sendAnonymousTelemetry"));
    decide(&Inputs {
        managed_forced: &managed.forced,
        settings: settings.as_ref(),
        app_choice,
        release_build,
        env: &env,
    })
}

/// A reverse-DNS bundle id (letters, digits, `.`, `-`, `_`).
fn valid_bundle_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 255
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'-' | b'_'))
}

/// A boolean (or number) preference of another app's domain, read fresh
/// from cfprefsd; None when unset or not a boolean.
#[cfg(target_os = "macos")]
pub fn app_preference(bundle_id: &str, key: &str) -> Option<bool> {
    use std::ffi::c_void;
    type CFTypeRef = *const c_void;
    const UTF8: u32 = 0x0800_0100;
    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        fn CFRelease(cf: CFTypeRef);
        fn CFGetTypeID(cf: CFTypeRef) -> usize;
        fn CFBooleanGetTypeID() -> usize;
        fn CFBooleanGetValue(b: CFTypeRef) -> u8;
        fn CFNumberGetTypeID() -> usize;
        fn CFNumberGetValue(n: CFTypeRef, kind: isize, out: *mut c_void) -> u8;
        fn CFStringCreateWithBytes(
            alloc: CFTypeRef,
            bytes: *const u8,
            len: isize,
            encoding: u32,
            external: u8,
        ) -> CFTypeRef;
        fn CFPreferencesAppSynchronize(app: CFTypeRef) -> u8;
        fn CFPreferencesCopyAppValue(key: CFTypeRef, app: CFTypeRef) -> CFTypeRef;
    }
    let string = |text: &str| -> CFTypeRef {
        // SAFETY: the bytes outlive the call, which copies them.
        unsafe {
            CFStringCreateWithBytes(
                std::ptr::null(),
                text.as_ptr(),
                isize::try_from(text.len()).unwrap_or(0),
                UTF8,
                0,
            )
        }
    };
    let app = string(bundle_id);
    let name = string(key);
    if app.is_null() || name.is_null() {
        for cf in [app, name] {
            if !cf.is_null() {
                // SAFETY: made by a Create call above, released once.
                unsafe { CFRelease(cf) };
            }
        }
        return None;
    }
    // SAFETY: valid CFStrings; the copied value is released below.
    let value = unsafe {
        CFPreferencesAppSynchronize(app);
        CFPreferencesCopyAppValue(name, app)
    };
    let out = if value.is_null() {
        None
    } else {
        // SAFETY: `value` is a live CF object owned here.
        let answer = unsafe {
            let kind = CFGetTypeID(value);
            if kind == CFBooleanGetTypeID() {
                Some(CFBooleanGetValue(value) != 0)
            } else if kind == CFNumberGetTypeID() {
                let mut n: i64 = 0;
                // kCFNumberSInt64Type = 4.
                (CFNumberGetValue(value, 4, (&mut n as *mut i64).cast()) != 0).then_some(n != 0)
            } else {
                None
            }
        };
        // SAFETY: the Copy call's value, released once.
        unsafe { CFRelease(value) };
        answer
    };
    // SAFETY: made by the Create calls above, released once.
    unsafe {
        CFRelease(app);
        CFRelease(name);
    }
    out
}

#[cfg(not(target_os = "macos"))]
pub fn app_preference(_bundle_id: &str, _key: &str) -> Option<bool> {
    None
}
