use cmux_process::{Command, Stdio};
use std::sync::Mutex as StdMutex;
use std::time::Duration;

/// Cursor CLI uses the login Keychain on macOS. Query item metadata without requesting the token.
pub(super) fn cursor_login_keychain_item_exists(refresh: bool) -> bool {
    static CACHE: CursorProbeCache = CursorProbeCache(StdMutex::new(None));
    CACHE.check(refresh, std::time::Instant::now, || {
        probe_status(
            Command::new("/usr/bin/security").args([
                "find-generic-password",
                "-s",
                "cursor-access-token",
                "-a",
                "cursor-user",
            ]),
            Duration::from_secs(1),
        )
    })
}

struct CursorProbeCache(StdMutex<Option<(std::time::Instant, bool)>>);

impl CursorProbeCache {
    fn check(
        &self,
        refresh: bool,
        now: impl Fn() -> std::time::Instant,
        probe: impl FnOnce() -> bool,
    ) -> bool {
        // The probe runs on a blocking worker. Hold the cache lock so concurrent reads share it.
        let mut cached = self.0.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some((checked, present)) = *cached
            && !refresh
            && now().saturating_duration_since(checked) < Duration::from_secs(30)
        {
            return present;
        }
        let present = probe();
        *cached = Some((now(), present));
        present
    }
}

fn probe_status(command: &mut Command, limit: Duration) -> bool {
    let Ok(mut child) =
        command.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).spawn()
    else {
        return false;
    };
    if let Ok(Some(status)) = child.wait_timeout(limit) {
        return status.success();
    }
    let _ = child.kill();
    let _ = child.wait();
    false
}

#[cfg(test)]
#[path = "cursor_keychain_tests.rs"]
mod tests;
