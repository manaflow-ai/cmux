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

/// The two unit files, as [`install_script`] names them.
const UNITS: &str = "acpmux-update.service acpmux-update.timer";

/// Installs the two units and starts the timer; it runs once
/// `acpmux.service` (re)started. A unit file that is missing is written; one
/// with the same text is kept; one with other text was written by someone
/// else and is theirs, so neither file is written and the timer is not
/// started (the reason goes to stderr). With [`NO_AUTO_UPDATE`] the timer is
/// stopped instead. Nothing here fails the script it runs in.
pub(super) fn install_script() -> String {
    format!(
        r#"au_d=~/.config/systemd/user
if [ -e {REMOTE_HOME}/{NO_AUTO_UPDATE} ]; then systemctl --user disable --now acpmux-update.timer >/dev/null 2>&1 || :
elif au_t=$(mktemp -d); then
cat > "$au_t/acpmux-update.service" <<'ACPMUX_UPDATE_UNIT'
{UPDATE_SERVICE}ACPMUX_UPDATE_UNIT
cat > "$au_t/acpmux-update.timer" <<'ACPMUX_UPDATE_UNIT'
{UPDATE_TIMER}ACPMUX_UPDATE_UNIT
au_c=; au_w=
for au_f in {UNITS}; do if [ -e "$au_d/$au_f" ] && ! cmp -s "$au_t/$au_f" "$au_d/$au_f"; then au_c=$au_f; fi; done
if [ -n "$au_c" ]; then echo "$au_d/$au_c differs from the unit acpmux writes, so this host does not update itself: remove it, then run host update again" >&2
else
for au_f in {UNITS}; do if [ ! -e "$au_d/$au_f" ]; then mkdir -p "$au_d" && cp "$au_t/$au_f" "$au_d/$au_f" && au_w=1; fi; done
if [ -z "$au_w" ] || systemctl --user daemon-reload; then systemctl --user enable --now acpmux-update.timer >/dev/null 2>&1 || :; fi
fi
rm -rf "$au_t"
fi
"#
    )
}
