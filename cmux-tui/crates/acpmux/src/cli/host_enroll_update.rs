//! The `update` step of `host enroll` and `host doctor`: how the host's
//! daemon stays on a current build once it is added. A Linux host updates
//! itself with `acpmux-update.timer` (`host_auto_update.rs`), which enroll
//! installs when it is missing, also on a host whose daemon was already
//! running this build (the daemon step installs it only when it restarts the
//! daemon). A Mac is moved to the build of the cmux that connects to it (the
//! app's peer updates, `host update`), and a cmux Cloud VM by cmux Cloud
//! (`cmux link machine update --to-bundled`); neither changes here. A Cloud
//! VM whose daemon is acpmux's own `acpmux.service` (a fleet lane host,
//! `hosts::cloud_vm_check`) is not cmux's to move, so it gets the timer.

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
/// exists (one systemd would apply once acpmux writes the unit): what the
/// manager lists, and a `NAME.d` or `acpmux-.TYPE.d` directory in any user
/// unit path (`systemd-analyze --user unit-paths`, and the defaults when it
/// cannot say). A drop-in for every service or timer (`service.d`) counts
/// too, on disk or in the manager's `DropInPaths`, unless this user neither
/// owns nor can write it, its directory or the directory above: then the
/// system's administrator put it there (a distribution ships them: Fedora's
/// `10-timeout-abort.conf`), whatever the path says. Every file in such a
/// directory counts, dot-files included, and a link there that points
/// nowhere is foreign. The paths are
/// `systemd-analyze`'s, the running manager's `UnitPath` (whose environment
/// may differ from this shell's: a path made of its space-separated pieces
/// that exists counts as foreign, and a list with two spaces or a tab in a
/// row is not read) and the defaults. A unit file of either name in any of
/// them but `~/.config/systemd/user` is foreign too (a reload would load it
/// over acpmux's). A unit path this user cannot search, or one under a
/// directory they cannot search, is not read: the probe is not `checked`;
/// nor is it when `~/.acpmux` (which holds the off mark) cannot be searched.
/// `linger` says the user's manager outlives the ssh session (`loginctl`),
/// which a timer needs. They are
/// acpmux's own only when each file there holds acpmux's own text, each unit
/// the manager knows loads from there, and no drop-in exists for either;
/// any other is someone else's (`foreign`), which runs what it likes. An
/// `XDG_CONFIG_HOME` other than `~/.config`, in this shell or the manager,
/// is `xdg`: systemd reads user units from there, and acpmux writes them only
/// in `~/.config/systemd/user`. Its words follow its own `begin` line (what
/// a shell prints before it is not read), and `checked`, its last line,
/// closes a probe that read the manager, its unit paths
/// (`systemd-analyze` and `UnitPath` both answered) and its units to the
/// end; without it nothing is installed. Paths are never globbed. acpmux's own timer is
/// `timer` when enabled and running, `stopped` otherwise (a missing file
/// too: `--fix` writes it).
pub(super) fn probe_script() -> String {
    let home = hosts::REMOTE_HOME;
    let off = hosts::NO_AUTO_UPDATE;
    let cloud = hosts::CLOUD_VM_MARK;
    let cloud_dir = cloud.rsplit_once('/').map_or("/", |(dir, _)| dir);
    let cloud_check = hosts::cloud_vm_check();
    let service = hosts::UPDATE_SERVICE;
    let timer = hosts::UPDATE_TIMER;
    format!(
        r#"echo {MARK}begin; au_o=$(uname -s) && echo "{MARK}os=$au_o"
{cloud_check}if [ -n "$acpmux_cloud" ]; then echo {MARK}cloud; elif [ -e {cloud} ]; then :; elif [ -e {cloud_dir} ] && [ ! -x {cloud_dir} ]; then echo {MARK}cloud-unknown; fi; [ ! -e {home}/{off} ] || echo {MARK}off
if au_e=$(systemctl --user show-environment 2>/dev/null); then echo {MARK}systemd; set -f; au_ok=1
[ ! -e {home} ] || [ -x {home} ] || au_ok=
au_m=; au_i=$IFS; IFS='
'; for au_v in $au_e; do case "$au_v" in XDG_CONFIG_HOME=*) au_m=${{au_v#XDG_CONFIG_HOME=}} ;; esac; done; IFS=$au_i
for au_v in "${{XDG_CONFIG_HOME:-}}" "$au_m"; do [ -z "$au_v" ] || [ "$au_v" = "$HOME/.config" ] || echo {MARK}xdg; done
au_lines() {{ au_i=$IFS; IFS=$2; for au_v in $1; do printf '%s%s\n' "$au_v" "$3"; done; IFS=$au_i; }}
au_mine() {{ [ -O "$1" ] || [ -w "$1" ] || [ -O "${{1%/*}}" ] || [ -w "${{1%/*}}" ]; }}
au_d=$HOME/.config/systemd/user; au_there=; au_own=1; au_all=1
au_r=${{XDG_RUNTIME_DIR:-}}; [ -n "$au_r" ] || {{ au_r=/run/user/$(id -u) || au_ok=; }}
au_c=${{XDG_CONFIG_HOME:-$HOME/.config}}; au_l=${{XDG_DATA_HOME:-$HOME/.local/share}}
au_u=$(systemctl --user show -p UnitPath --value 2>/dev/null) && [ -n "$au_u" ] || au_ok=
au_a=$(systemd-analyze --user unit-paths 2>/dev/null) && [ -n "$au_a" ] || au_ok=
case "$au_u" in *"  "*|*"	"*) au_ok= ;; esac
au_g=; for au_e in $au_u; do case "$au_e" in /*) ;; *) au_there=1; au_own= ;; esac
au_k=; au_i=$IFS; IFS='
'; for au_h in $au_g; do [ ! -e "$au_h $au_e" ] || {{ au_there=1; au_own=; }}; au_k="$au_k$au_h $au_e
"; done; IFS=$au_i; au_g="$au_k$au_e
"; done
au_paths="$au_a
$(au_lines "$au_u" ' ' '')
$au_d
$au_c/systemd/user.control
$au_c/systemd/user
$(au_lines "${{XDG_CONFIG_DIRS:-/etc/xdg}}" : /systemd/user)
/etc/systemd/user
$au_r/systemd/user.control
$au_r/systemd/transient
$au_r/systemd/generator.early
$au_r/systemd/user
/run/systemd/user
$au_r/systemd/generator
$au_l/systemd/user
$(au_lines "${{XDG_DATA_DIRS:-/usr/local/share:/usr/share}}" : /systemd/user)
/usr/local/lib/systemd/user
/usr/lib/systemd/user
/lib/systemd/user
$au_r/systemd/generator.late"
for au_f in acpmux-update.service acpmux-update.timer; do
au_s=$(systemctl --user show "$au_f" -p LoadState --value 2>/dev/null) || au_s=error
if [ -e "$au_d/$au_f" ] || [ -L "$au_d/$au_f" ]; then au_there=1; else au_all=; fi
case "$au_s" in not-found) ;; *) au_there=1
[ "$au_s" = loaded ] && [ "$(systemctl --user show "$au_f" -p FragmentPath --value 2>/dev/null)" = "$au_d/$au_f" ] || au_own= ;; esac
au_x=$(systemctl --user show "$au_f" -p DropInPaths --value 2>/dev/null) || au_x=error
for au_y in $au_x; do case "$au_y" in */"${{au_f##*.}}".d/*) ! au_mine "$au_y" && ! au_mine "${{au_y%/*}}" ;; *) false ;; esac || {{ au_there=1; au_own=; }}; done
au_i=$IFS; IFS='
'; for au_p in $au_paths; do [ -n "$au_p" ] || continue
au_t=$au_p; while [ -n "$au_t" ] && [ ! -e "$au_t" ]; do au_v=${{au_t%/*}}; [ "$au_v" != "$au_t" ] || {{ au_ok=; break; }}; au_t=$au_v; done
[ -z "$au_t" ] || [ ! -d "$au_t" ] || [ -x "$au_t" ] || au_ok=
[ ! -d "$au_p" ] || [ -x "$au_p" ] || au_ok=
[ ! -e "$au_p/$au_f" ] && [ ! -L "$au_p/$au_f" ] || [ "$au_p/$au_f" -ef "$au_d/$au_f" ] || {{ au_there=1; au_own=; }}
for au_n in "$au_f.d" "acpmux-.${{au_f##*.}}.d"; do [ ! -d "$au_p/$au_n" ] || {{ au_there=1; au_own=; }}; done
au_w="$au_p/${{au_f##*.}}.d"; [ ! -d "$au_w" ] || ! au_mine "$au_w" || {{ au_there=1; au_own=; }}
set +f; set -- "$au_w"/* "$au_w"/.[!.]* "$au_w"/..?*; set -f
for au_z in "$@"; do if [ -L "$au_z" ] && [ ! -e "$au_z" ]; then au_there=1; au_own=; elif [ -e "$au_z" ] && au_mine "$au_z"; then au_there=1; au_own=; fi; done; done; IFS=$au_i
done
if [ -n "$au_there" ]; then
[ ! -e "$au_d/acpmux-update.service" ] && [ ! -L "$au_d/acpmux-update.service" ] || {{ [ -f "$au_d/acpmux-update.service" ] && [ ! -L "$au_d/acpmux-update.service" ] && cmp -s - "$au_d/acpmux-update.service"; }} <<'ACPMUX_UPDATE_SERVICE' || au_own=
{service}ACPMUX_UPDATE_SERVICE
[ ! -e "$au_d/acpmux-update.timer" ] && [ ! -L "$au_d/acpmux-update.timer" ] || {{ [ -f "$au_d/acpmux-update.timer" ] && [ ! -L "$au_d/acpmux-update.timer" ] && cmp -s - "$au_d/acpmux-update.timer"; }} <<'ACPMUX_UPDATE_TIMER' || au_own=
{timer}ACPMUX_UPDATE_TIMER
if [ -z "$au_own" ]; then echo {MARK}foreign
elif [ -n "$au_all" ] && [ "$(systemctl --user is-enabled acpmux-update.timer 2>/dev/null)" = enabled ] && systemctl --user is-active --quiet acpmux-update.timer; then echo {MARK}timer
else echo {MARK}stopped; fi
fi
[ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)" != yes ] || echo {MARK}linger
set +f; [ -z "$au_ok" ] || echo {MARK}checked
fi"#
    )
}

/// [`hosts::install_script`], run only when [`probe_script`], run again
/// under the update lock, read everything (`checked`, its last line) and found no unit or
/// drop-in acpmux did not write and no other `XDG_CONFIG_HOME`, once the
/// user's manager lingers (asked for when it does not, as `host setup` does);
/// else it prints `foreign`, `xdg`, `unchecked` or `nolinger` and writes
/// nothing.
pub(super) fn guarded_install_script() -> String {
    format!(
        "au_probe() {{\n{probe}\n}}\nau_o=$(au_probe); echo {MARK}begin\ncase \"$au_o\" in *{MARK}foreign*) echo {MARK}foreign ;; *{MARK}xdg*) echo {MARK}xdg ;; *\"\n{MARK}checked\")\nif {linger}; then\n{install}\nelse echo {MARK}nolinger; fi\n;; *) echo {MARK}unchecked ;; esac",
        probe = probe_script(),
        linger = hosts::SYSTEMD_LINGERING,
        install = hosts::install_script(),
    )
}

/// What [`probe_script`] found.
#[derive(Debug, Default, PartialEq, Eq)]
pub(super) struct Found {
    pub os: String,
    pub cloud: bool,
    pub off: bool,
    pub systemd: bool,
    /// `/etc/cmux` is there but cannot be read: whether it is a Cloud VM is
    /// not known.
    pub cloud_unknown: bool,
    /// acpmux's own timer is enabled and running.
    pub timer: bool,
    /// acpmux's own timer is enabled but not running.
    pub stopped: bool,
    /// An enabled `acpmux-update.timer` that acpmux did not write.
    pub foreign: bool,
    /// systemd reads user units from another `XDG_CONFIG_HOME`.
    pub xdg: bool,
    /// The probe read the manager and its units to the end.
    pub checked: bool,
    /// The probe under the update lock did not: nothing was installed.
    pub unchecked: bool,
    /// The user's manager lingers, so it outlives the ssh session.
    pub linger: bool,
    /// Lingering is off and could not be turned on: nothing was installed.
    pub nolinger: bool,
}

/// The words after the script's own (last) `begin` line; `checked` counts
/// only as the last line.
pub(super) fn parse(stdout: &str) -> Found {
    let mut found = Found::default();
    let lines: Vec<&str> = stdout.lines().map(str::trim).filter(|l| !l.is_empty()).collect();
    let begin = format!("{MARK}begin");
    let Some(start) = lines.iter().rposition(|l| *l == begin) else { return found };
    let mine = lines.get(start + 1..).unwrap_or_default();
    found.checked = mine.last().and_then(|l| l.strip_prefix(MARK)) == Some("checked");
    for word in mine.iter().filter_map(|line| line.strip_prefix(MARK)) {
        match word {
            "cloud" => found.cloud = true,
            "cloud-unknown" => found.cloud_unknown = true,
            "off" => found.off = true,
            "systemd" => found.systemd = true,
            "timer" => found.timer = true,
            "stopped" => found.stopped = true,
            "foreign" => found.foreign = true,
            "xdg" => found.xdg = true,
            "checked" => {}
            "unchecked" => found.unchecked = true,
            "linger" => found.linger = true,
            "nolinger" => found.nolinger = true,
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
/// host's update lock; without `fix` nothing changes. `cmux_own`: the path of
/// cmux's own acpmux when that runs the daemon (the app's install, a cmux
/// session daemon): the timer runs `~/.local/bin/acpmux host self-update`, a
/// standalone acpmux's updater, so it is never installed there.
pub(super) fn update(r: &dyn Remote, fix: bool, cmux_own: Option<&str>) -> StepResult {
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
    if let Some(path) = cmux_own {
        return StepResult::new(
            Step::Update,
            StepState::Skip,
            format!(
                "cmux's own acpmux runs here ({path}): it is updated with cmux, as the install step says, not by acpmux-update.timer"
            ),
        );
    }
    if found.os != "Linux" || found.cloud_unknown {
        let what =
            if found.os.is_empty() { "an unknown system".to_owned() } else { found.os.clone() };
        let why = if found.cloud_unknown {
            "cannot tell whether this is a cmux Cloud VM".to_owned()
        } else {
            format!("acpmux-update.timer is for Linux, and this is {what}")
        };
        return warn(
            format!(
                "{why}, so it is left as it is; cmux moves it to the app's build each time it connects"
            ),
            None,
        );
    }
    if !found.systemd {
        return warn(
            "no user systemd here, so it cannot update itself; cmux moves it to the app's build each time it connects",
            None,
        );
    }
    if !found.checked {
        return unread(host);
    }
    if found.foreign {
        return foreign(host);
    }
    if found.xdg {
        return xdg();
    }
    if found.timer && found.linger {
        return ok(EVERY);
    }
    if found.timer && !fix {
        return no_linger(host, false);
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
        .and_then(|lock| hosts::run(&lock.fence(r), &guarded_install_script()));
    let out = match ran {
        Ok(out) => out,
        Err(e) => return warn(format!("installing acpmux-update.timer failed: {e:#}"), Some(host)),
    };
    let again = parse(&out);
    if again.foreign {
        return foreign(host);
    }
    if again.xdg {
        return xdg();
    }
    if again.unchecked {
        return unread(host);
    }
    if again.nolinger {
        return no_linger(host, true);
    }
    if let Some(why) = hosts::take_auto_update_off(&out).1 {
        return warn(why, None);
    }
    match r.exec(&probe_script(), None) {
        Ok(after)
            if after.ok && {
                let a = parse(&after.stdout);
                a.checked && a.timer && a.linger
            } =>
        {
            StepResult::new(
                Step::Update,
                StepState::Fixed,
                format!("installed acpmux-update.timer: it {EVERY}"),
            )
        }
        _ => warn("acpmux-update.timer was installed but is not running", Some(host)),
    }
}

/// The probe did not read the manager and its units to the end: nothing is
/// written.
fn unread(host: &str) -> StepResult {
    warn(
        format!(
            "could not read acpmux-update's units on {host} to the end, so nothing was written"
        ),
        Some(host),
    )
}

/// The user's manager does not linger, so the timer would stop at logout.
fn no_linger(host: &str, asked: bool) -> StepResult {
    let detail = if asked {
        "this user's systemd manager does not linger and loginctl enable-linger was refused, so acpmux-update.timer would stop at logout; cmux moves it to the app's build each time it connects"
    } else {
        "this user's systemd manager does not linger, so acpmux-update.timer stops at logout"
    };
    let result = StepResult::new(Step::Update, StepState::Warn, detail);
    if asked {
        result.with_fix(format!("Run loginctl enable-linger on {host} (or ask its administrator), then check again with --fix."))
    } else {
        result.with_fix(format!("Check again with --fix to turn on lingering for {host}."))
    }
}

/// Another `XDG_CONFIG_HOME`: nothing is written.
fn xdg() -> StepResult {
    warn(
        "this host sets XDG_CONFIG_HOME, so systemd reads user units from there, and acpmux writes acpmux-update.timer only in ~/.config/systemd/user; cmux moves it to the app's build each time it connects",
        None,
    )
}

/// A unit or drop-in acpmux did not write: nothing is written.
fn foreign(host: &str) -> StepResult {
    warn(
        "an acpmux-update unit or drop-in acpmux did not write is here, so cmux does not know what it runs, and leaves it alone",
        None,
    )
    .with_fix(format!(
        "Remove the acpmux-update units and drop-ins acpmux did not write on {host}, then check again with --fix."
    ))
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
