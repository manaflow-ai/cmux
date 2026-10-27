//! The timer that keeps a Linux host's daemon on the newest feat-cmux-next
//! build by itself: `acpmux-update.timer` starts `acpmux-update.service`,
//! which runs `acpmux host self-update` (`host_self_update.rs`). `host
//! setup` and every `host update` install both units next to
//! `acpmux.service`, so a host set up earlier gets them at its next update;
//! `host setup --no-auto-update` leaves the marker [`NO_AUTO_UPDATE`] that
//! keeps them off.

use super::REMOTE_HOME;

/// The marker in the remote acpmux home that turns automatic updates off:
/// the units are not installed, a timer already there is stopped, and
/// `host self-update` does nothing. Removing it turns them on again at the
/// next update.
pub(super) const NO_AUTO_UPDATE: &str = "no-auto-update";

/// The oneshot service the timer starts. `KillMode=process`: a daemon the
/// update had to start detached (a host without `acpmux.service`) outlives
/// the service. The start timeout bounds a download that hangs. It sets no
/// `ACPMUX_HOME` or `ACPMUX_SOCKET`: every update script reads the daemon's
/// from `acpmux.service` and its drop-ins (`SERVICE_ENV`, `host_update.rs`).
pub(super) const UPDATE_SERVICE: &str = "[Unit]
Description=acpmux self-update (newest feat-cmux-next build)

[Service]
Type=oneshot
Environment=PATH=%h/.local/bin:%h/.bun/bin:%h/.cargo/bin:%h/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=%h/.local/bin/acpmux host self-update --json
WorkingDirectory=%h
KillMode=process
TimeoutStartSec=15min
";

/// Every 15 minutes, the first 5 minutes after the timer starts (at boot,
/// or when an update installs it), spread by up to 2 minutes so the hosts of
/// one fleet do not restart together. `OnActiveSec`, not `OnBootSec`: a
/// timer started after its `OnBootSec` passed elapses at once, which would
/// race the `host update` that just installed it.
pub(super) const UPDATE_TIMER: &str = "[Unit]
Description=acpmux self-update every 15 minutes

[Timer]
OnActiveSec=5min
OnUnitActiveSec=15min
RandomizedDelaySec=2min
Persistent=true

[Install]
WantedBy=timers.target
";

/// Starts the line [`install_script`] prints, on stdout, when it leaves the
/// host without its self-update (a unit someone else wrote, a failed write):
/// why, and what to do. `host setup`, `host update` and `host enroll --fix`
/// take it out of the script's output ([`take_auto_update_off`]) and put it
/// in their rows.
pub(super) const AUTO_UPDATE_OFF: &str = "ACPMUX_AUTO_UPDATE_OFF=";

/// `out` without its [`AUTO_UPDATE_OFF`] lines, and the reason the last one gave.
pub(super) fn take_auto_update_off(out: &str) -> (String, Option<String>) {
    let mut off = None;
    let rest: Vec<&str> = out
        .lines()
        .filter(|line| match line.strip_prefix(AUTO_UPDATE_OFF) {
            Some(why) => {
                off = Some(why.trim().to_owned());
                false
            }
            None => true,
        })
        .collect();
    (rest.join("\n"), off)
}

/// The two unit files, as [`install_script`] names them.
const UNITS: &str = "acpmux-update.service acpmux-update.timer";

/// Sets `$au_c` when the running user manager already has unit `$au_f`
/// from somewhere else: masked, loaded from a file other than `$au_d/$au_f`
/// (`/etc/systemd/user`, a runtime or `$XDG_DATA_HOME` directory: whatever
/// path that manager reads, which a shell's environment may not share), or
/// not answering (fail closed). Two calls, one property each: with both,
/// `--value` prints them in systemd's order, not the order asked.
const MANAGER_HAS_UNIT: &str = r#"au_s=$(systemctl --user show "$au_f" -p LoadState --value 2>/dev/null) || au_s=
au_g=$(systemctl --user show "$au_f" -p FragmentPath --value 2>/dev/null) || au_g=
case "$au_s" in
not-found) ;;
loaded) [ "$au_g" = "$au_d/$au_f" ] || au_c=$au_g ;;
*) au_c="$au_f (${au_s:-no answer from the user manager})" ;;
esac
"#;

/// Installs the two units and starts the timer; it runs once
/// `acpmux.service` (re)started. A unit file that is missing is written
/// (staged, then copied beside and renamed, so a cut-off copy is never
/// taken for theirs; a failed write starts nothing); one with the same text is kept; one with
/// other text was written by someone else and is theirs, so neither file is
/// written and the timer is not started (the reason goes to stdout, as [`AUTO_UPDATE_OFF`]). The
/// same holds when the running user manager has either unit from anywhere
/// else, or is masked, or cannot say ([`MANAGER_HAS_UNIT`]): a file written
/// here would shadow theirs. With [`NO_AUTO_UPDATE`] the timer is stopped
/// instead, and only when the timer is acpmux's (whatever the service is): a
/// timer someone else wrote keeps running (review of #24232). Nothing here
/// fails the script it runs in.
pub(super) fn install_script() -> String {
    format!(
        r#"au_d=$HOME/.config/systemd/user
au_t=
if au_t=$(mktemp -d) && cat > "$au_t/acpmux-update.service" <<'ACPMUX_UPDATE_SERVICE' && cat > "$au_t/acpmux-update.timer" <<'ACPMUX_UPDATE_TIMER'; then
{UPDATE_SERVICE}ACPMUX_UPDATE_SERVICE
{UPDATE_TIMER}ACPMUX_UPDATE_TIMER
au_c=; au_w=; au_e=; au_ct=
for au_f in {UNITS}; do au_o=$au_c; au_c=
if [ -e "$au_d/$au_f" ] && ! cmp -s "$au_t/$au_f" "$au_d/$au_f"; then au_c=$au_d/$au_f; fi
{MANAGER_HAS_UNIT}if [ -n "$au_c" ]; then [ "$au_f" != acpmux-update.timer ] || au_ct=$au_c; else au_c=$au_o; fi
done
if [ -e {REMOTE_HOME}/{NO_AUTO_UPDATE} ]; then [ -n "$au_ct" ] || systemctl --user disable --now acpmux-update.timer >/dev/null 2>&1 || :
elif [ -n "$au_c" ]; then echo "{AUTO_UPDATE_OFF}$au_c is a unit acpmux did not write, so this host does not update itself: remove it, then run host update again"
else
for au_f in {UNITS}; do if [ ! -e "$au_d/$au_f" ]; then if mkdir -p "$au_d" && cp "$au_t/$au_f" "$au_d/.$au_f.part" && mv -f "$au_d/.$au_f.part" "$au_d/$au_f"; then au_w=1; else rm -f "$au_d/.$au_f.part"; au_e=1; fi; fi; done
if [ -n "$au_e" ]; then echo "{AUTO_UPDATE_OFF}writing the acpmux-update units in $au_d failed, so this host does not update itself yet: the next host update tries again"
elif [ -z "$au_w" ] || systemctl --user daemon-reload; then systemctl --user enable --now acpmux-update.timer >/dev/null 2>&1 || :; fi
fi
rm -rf "$au_t"
else [ -e {REMOTE_HOME}/{NO_AUTO_UPDATE} ] || echo "{AUTO_UPDATE_OFF}staging the acpmux-update units failed, so this host does not update itself yet: the next host update tries again"; [ -z "$au_t" ] || rm -rf "$au_t"
fi
"#
    )
}
