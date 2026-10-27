//! The `update` step of `host enroll` and `host doctor`: how the host's
//! daemon stays on a current build once it is added. A Linux host updates
//! itself with `acpmux-update.timer` (`host_auto_update.rs`), which enroll
//! installs when it is missing, also on a host whose daemon was already
//! running this build (the daemon step installs it only when it restarts the
//! daemon). A Mac is moved to the build of the cmux that connects to it (the
//! app's peer updates, `host update`), and a cmux Cloud VM by cmux Cloud
//! (`cmux link machine update --to-bundled`); neither changes here.

use super::hosts;
use crate::cli::host_steps::{Step, StepResult, StepState};
use crate::cli::hosts::Remote;

/// Starts each line of [`probe_script`], so a login banner is not read as one.
const MARK: &str = "ACPMUX_AU=";

/// What the step reads before it changes anything: the kernel, whether the
/// host is a cmux Cloud VM, whether automatic updates were turned off, and
/// whether a user systemd manager runs, and the timer's units. A unit is
/// there when the manager knows it (any load state but `not-found`) or its
/// file is in `~/.config/systemd/user`, enabled or not, or a drop-in for it
/// exists (one systemd would apply once acpmux writes the unit). They are
/// acpmux's own only when each file there holds acpmux's own text, each unit
/// the manager knows loads from there, and no drop-in exists for either;
/// any other is someone else's (`foreign`), which runs what it likes. acpmux's own timer is
/// `timer` when enabled and running, `stopped` otherwise (a missing file
/// too: `--fix` writes it).
pub(super) fn probe_script() -> String {
    let home = hosts::REMOTE_HOME;
    let off = hosts::NO_AUTO_UPDATE;
    let cloud = hosts::CLOUD_VM_MARK;
    let service = hosts::UPDATE_SERVICE;
    let timer = hosts::UPDATE_TIMER;
    format!(
        r#"echo "{MARK}os=$(uname -s)"; [ ! -e {cloud} ] || echo {MARK}cloud; [ ! -e {home}/{off} ] || echo {MARK}off
if systemctl --user show-environment >/dev/null 2>&1; then echo {MARK}systemd
au_d=$HOME/.config/systemd/user; au_there=; au_own=1; au_all=1
for au_f in acpmux-update.service acpmux-update.timer; do
au_s=$(systemctl --user show "$au_f" -p LoadState --value 2>/dev/null) || au_s=error
if [ -e "$au_d/$au_f" ]; then au_there=1; else au_all=; fi
case "$au_s" in not-found) ;; *) au_there=1
[ "$au_s" = loaded ] && [ "$(systemctl --user show "$au_f" -p FragmentPath --value 2>/dev/null)" = "$au_d/$au_f" ] || au_own= ;; esac
au_x=$(systemctl --user show "$au_f" -p DropInPaths --value 2>/dev/null) || au_x=error; [ -z "$au_x" ] || {{ au_there=1; au_own=; }}
for au_p in "$au_d" "${{XDG_CONFIG_HOME:-$HOME/.config}}/systemd/user" /etc/systemd/user "$HOME/.local/share/systemd/user" /usr/local/lib/systemd/user /usr/lib/systemd/user /run/systemd/user; do
[ ! -d "$au_p/$au_f.d" ] || {{ au_there=1; au_own=; }}; done
done
if [ -n "$au_there" ]; then
[ ! -e "$au_d/acpmux-update.service" ] || cmp -s - "$au_d/acpmux-update.service" <<'ACPMUX_UPDATE_SERVICE' || au_own=
{service}ACPMUX_UPDATE_SERVICE
[ ! -e "$au_d/acpmux-update.timer" ] || cmp -s - "$au_d/acpmux-update.timer" <<'ACPMUX_UPDATE_TIMER' || au_own=
{timer}ACPMUX_UPDATE_TIMER
if [ -z "$au_own" ]; then echo {MARK}foreign
elif [ -n "$au_all" ] && [ "$(systemctl --user is-enabled acpmux-update.timer 2>/dev/null)" = enabled ] && systemctl --user is-active --quiet acpmux-update.timer; then echo {MARK}timer
else echo {MARK}stopped; fi
fi
fi"#
    )
}

/// What [`probe_script`] found.
#[derive(Debug, Default, PartialEq, Eq)]
pub(super) struct Found {
    pub os: String,
    pub cloud: bool,
    pub off: bool,
    pub systemd: bool,
    /// acpmux's own timer is enabled and running.
    pub timer: bool,
    /// acpmux's own timer is enabled but not running.
    pub stopped: bool,
    /// An enabled `acpmux-update.timer` that acpmux did not write.
    pub foreign: bool,
}

pub(super) fn parse(stdout: &str) -> Found {
    let mut found = Found::default();
    for word in stdout.lines().filter_map(|line| line.trim().strip_prefix(MARK)) {
        match word {
            "cloud" => found.cloud = true,
            "off" => found.off = true,
            "systemd" => found.systemd = true,
            "timer" => found.timer = true,
            "stopped" => found.stopped = true,
            "foreign" => found.foreign = true,
            other => {
                if let Some(os) = other.strip_prefix("os=") {
                    os.clone_into(&mut found.os);
                }
            }
        }
    }
    found
}

const EVERY: &str = "updates itself to the newest build every 15 minutes (acpmux-update.timer)";

/// The step. With `fix`, a Linux host without the timer gets it, under the
/// host's update lock; without `fix` nothing changes.
pub(super) fn update(r: &dyn Remote, fix: bool) -> StepResult {
    let host = r.host();
    let found = match r.exec(&probe_script(), None) {
        Ok(out) if out.ok => parse(&out.stdout),
        Ok(out) => {
            let why = out.stderr.lines().rev().find(|l| !l.trim().is_empty()).unwrap_or("");
            return warn(format!("could not read how {host} updates: {}", why.trim()), None);
        }
        Err(e) => return warn(format!("could not read how {host} updates: {e:#}"), None),
    };
    let ok = |detail: &str| StepResult::new(Step::Update, StepState::Ok, detail);
    if found.off {
        return StepResult::new(
            Step::Update,
            StepState::Skip,
            format!("automatic updates are off ({}/{})", hosts::REMOTE_HOME, hosts::NO_AUTO_UPDATE),
        )
        .with_fix(format!(
            "Remove {}/{} on {host} to turn them on, then check again with --fix.",
            hosts::REMOTE_HOME,
            hosts::NO_AUTO_UPDATE
        ));
    }
    // A Mac and a Cloud VM never run the timer (cmux moves them on connect),
    // so a unit there is not read.
    if found.cloud {
        return ok("a cmux Cloud VM: cmux moves it to the app's build each time it connects");
    }
    if found.os == "Darwin" {
        return ok("a Mac: cmux moves it to this Mac's build each time it connects");
    }
    if found.timer {
        return ok(EVERY);
    }
    if found.foreign {
        return warn(
            "an acpmux-update unit or drop-in acpmux did not write is here, so cmux does not know what it runs, and leaves it alone",
            None,
        )
        .with_fix(format!(
            "Remove the acpmux-update units and drop-ins acpmux did not write on {host}, then check again with --fix."
        ));
    }
    if !found.systemd {
        return warn(
            "no user systemd here, so it cannot update itself; cmux moves it to your Mac's build each time it connects",
            None,
        );
    }
    if !fix {
        let (detail, verb) = if found.stopped {
            ("acpmux-update.timer is off or stopped, so it does not update itself", "start")
        } else {
            ("acpmux-update.timer is not installed, so it does not update itself", "install")
        };
        return StepResult::new(Step::Update, StepState::Warn, detail)
            .with_fix(format!("Check again with --fix to {verb} acpmux-update.timer on {host}."));
    }
    install(r, host)
}

/// Writes and starts the timer ([`hosts::install_script`]), then reads
/// whether it runs now.
fn install(r: &dyn Remote, host: &str) -> StepResult {
    let ran = hosts::lock_to_install(r)
        .and_then(|lock| hosts::run(&lock.fence(r), &hosts::install_script()));
    let out = match ran {
        Ok(out) => out,
        Err(e) => return warn(format!("installing acpmux-update.timer failed: {e:#}"), Some(host)),
    };
    if let Some(why) = hosts::take_auto_update_off(&out).1 {
        return warn(why, None);
    }
    match r.exec(&probe_script(), None) {
        Ok(after) if after.ok && parse(&after.stdout).timer => StepResult::new(
            Step::Update,
            StepState::Fixed,
            format!("installed acpmux-update.timer: it {EVERY}"),
        ),
        _ => warn("acpmux-update.timer was installed but is not running", Some(host)),
    }
}

/// A warning: the host works, but does not keep itself current. `again`
/// names the host a person checks again with --fix.
fn warn(detail: impl Into<String>, again: Option<&str>) -> StepResult {
    let result = StepResult::new(Step::Update, StepState::Warn, detail);
    match again {
        Some(host) => result.with_fix(format!("Check {host} again with --fix.")),
        None => result,
    }
}

#[cfg(test)]
#[path = "host_enroll_update_tests.rs"]
mod tests;
