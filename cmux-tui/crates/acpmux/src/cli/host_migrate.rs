//! Moving a daemon from a hand-written systemd unit (such as huge-blue's
//! `acpmux-agent-<host>.service`) to `acpmux.service` during `acpmux host
//! update`, and back when the update fails. Setup refuses such a unit
//! instead (`FOREIGN_UNIT_REFUSAL` in `hosts.rs`).

use super::{
    REMOTE_HOME, RESTORE_PREV, STILL_RUNNING_CHECK, SYSTEMD_LINGERING, SYSTEMD_STARTED,
    SYSTEMD_UNIT,
};

/// What a script prints before it refuses (exit 3) to move a hand-written
/// unit, followed by the reason's code; the message goes to stderr.
pub(super) const REFUSED: &str = "ACPMUX_REFUSED=";

/// What the migration prints, followed by the old unit, before its first
/// change: from then on a failed update moves the daemon back to that unit.
pub(super) const MIGRATING: &str = "ACPMUX_MIGRATING=";

/// The plan for moving the daemon from the hand-written unit `$u` to
/// `acpmux.service`, checked before anything changes, into the temporary
/// folder `$t`: `$t/d` gets the drop-ins `acpmux.service` needs to be the same
/// daemon. `ACPMUX_HOME` and `ACPMUX_SOCKET` (read from the daemon's own
/// environment, so systemd's `%h` is already expanded) are carried in
/// `10-migrated.conf`: a home unless it is `$dh` ([`REMOTE_HOME`]) byte for
/// byte, not through links (the daemon opens its home with `O_NOFOLLOW`,
/// `config::private_state_dir`, so on huge-blue, where `~/.acpmux` links to
/// the unit's home, acpmux.service without `ACPMUX_HOME` never starts), and
/// a socket always (a long one falls back to a path derived from the
/// variable, not from the home). The unit's own drop-ins
/// (`~/.config/systemd/user/<unit>.d/*.conf`, such as a memory limit) are
/// copied; one named `10-migrated.conf` is refused. Every later update
/// script reads the carried pair back from the unit (`SERVICE_ENV`,
/// `host_update.rs`). `daemon run` takes its listen address from `--listen`
/// alone, so a `--listen` the home's config.json does not also name is
/// refused rather than moved; `--log` is dropped, and any other argument is
/// refused.
const MIGRATE_PLAN: &str = r#"d=~/.config/systemd/user; n=$d/acpmux.service.d; t=
refuse() { [ -z "$t" ] || rm -rf "$t"; echo "ACPMUX_REFUSED=$1"; echo "$2" >&2; exit 3; }
[ -f "$d/$u" ] || refuse unitElsewhere "the daemon of ~/.acpmux runs under $u, whose unit file is not in $d: move it to acpmux.service by hand"
t=$(mktemp -d) && mkdir "$t/d" || exit 1
envof() { tr '\000' '\n' < "/proc/$p/environ" 2>/dev/null | sed -n "s/^$1=//p" | head -1; }
carry() { case "$2" in *[!A-Za-z0-9/._+@:-]*) refuse unitSettings "$u sets $1 to a value acpmux does not copy into a unit: move it to acpmux.service by hand";; esac; printf 'Environment=%s=%s\n' "$1" "$2" >> "$t/env"; }
h=$(envof ACPMUX_HOME); s=$(envof ACPMUX_SOCKET)
if [ -n "$h" ] && [ "$h" != "$dh" ]; then carry ACPMUX_HOME "$h"; fi
if [ -n "$s" ]; then carry ACPMUX_SOCKET "$s"; fi
[ ! -e "$d/$u.d/10-migrated.conf" ] || refuse unitSettings "$u has a drop-in named 10-migrated.conf, the name acpmux gives the settings it carries: rename it, then run this again"
if [ -d "$d/$u.d" ]; then find "$d/$u.d" -maxdepth 1 -type f -name '*.conf' -exec cp {} "$t/d/" \; ; fi
if [ -f "$t/env" ]; then { echo '[Service]'; cat "$t/env"; } > "$t/d/10-migrated.conf"; fi
l=; k=
while read -r x; do
case "$k" in --listen) l=$x; k=; continue;; --log) k=; continue;; esac
case "$x" in --listen|--log) k=$x;; --listen=*) l=${x#--listen=};; --log=*|'') ;; *) refuse unitArgs "$u runs the daemon with $x, which acpmux.service does not pass: move it by hand";; esac
done <<ACPMUX_ARGS
$(tr '\000' '\n' < "/proc/$p/cmdline" 2>/dev/null | sed '1,/^run$/d')
ACPMUX_ARGS
if [ -n "$l" ] && ! grep -q "\"listen\": *\"$l\"" "${h:-$HOME/.acpmux}/config.json" 2>/dev/null; then refuse listenConflict "$u runs the daemon with --listen $l, which is not the websocket.listen of its config.json, and acpmux.service reads the address only from there: set it to $l, then run this again"; fi
"#;

/// Refuses the move when `acpmux.service` or one of its drop-ins already
/// exists with other text than the plan's (`$t/acpmux.service`, `$t/d`):
/// someone wrote that unit, and it is theirs. One with the same text is
/// adopted as it is.
const MIGRATE_CONFLICTS: &str = r#"if [ -e "$d/acpmux.service" ] && ! cmp -s "$t/acpmux.service" "$d/acpmux.service"; then refuse unitConflict "$d/acpmux.service differs from the unit acpmux writes, so the daemon is not moved from $u to it: remove or fix it, then run this again"; fi
while read -r f; do [ -z "$f" ] || cmp -s "$f" "$t/d/${f##*/}" || refuse unitConflict "$f differs from what moving the daemon from $u to acpmux.service writes: remove or fix it, then run this again"; done <<ACPMUX_DROP_INS
$(find "$n" -maxdepth 1 -type f -name '*.conf' 2>/dev/null)
ACPMUX_DROP_INS
"#;

/// Writes the plan (files that exist already are kept: they matched), then
/// stops the old unit with the runtime drop-in `zzz-acpmux-migrate.conf` in
/// place: `KillMode=process` sends SIGTERM to the daemon alone, which leaves
/// its agents running for the next one to adopt (the unit's default
/// `control-group` would end every agent host in its cgroup), and the name
/// sorts after the unit's own drop-ins, so it wins.
const MIGRATE_STOP: &str = r#"echo "ACPMUX_MIGRATING=$u"
r="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/systemd/user/$u.d"
mkdir -p "$n" "$r" && printf '[Service]\nKillMode=process\nRestart=no\n' > "$r/zzz-acpmux-migrate.conf" || exit 1
[ -e "$d/acpmux.service" ] || cp "$t/acpmux.service" "$d/acpmux.service" || exit 1
find "$t/d" -type f -name '*.conf' -exec cp -n {} "$n/" \;
rm -rf "$t"
systemctl --user daemon-reload && systemctl --user disable --now "$u" || exit 1
"#;

/// Renames the old unit's file, so nothing (a timer that restarts it by
/// name) starts it again, and starts `acpmux.service` (exit 5 when it does
/// not start; the caller moves the daemon back).
const MIGRATE_START: &str = r#"mv "$d/$u" "$d/$u.migrated" && systemctl --user daemon-reload || exit 1
systemctl --user reset-failed acpmux.service >/dev/null 2>&1
systemctl --user enable --now acpmux.service || { echo "acpmux.service did not start after $u stopped" >&2; exit 5; }
"#;

/// Moves the daemon back to the unit `$u` it was moved from: stops
/// `acpmux.service` (`KillMode=process`, agents kept), restores the old unit's
/// file, drops the runtime drop-in and starts the old unit, which runs its
/// own binary. Never starts `acpmux.service` again.
const MIGRATE_BACK: &str = r#"d=~/.config/systemd/user; r="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/systemd/user/$u.d"
systemctl --user disable --now acpmux.service >/dev/null 2>&1
if [ -f "$d/$u.migrated" ] && [ ! -e "$d/$u" ]; then mv "$d/$u.migrated" "$d/$u"; fi
rm -f "$r/zzz-acpmux-migrate.conf"
systemctl --user daemon-reload && systemctl --user enable --now "$u"
"#;

/// Moves a daemon that runs under a hand-written acpmux unit (`$u` from
/// [`super::DAEMON_UNIT`]) to `acpmux.service`, keeping its agents; nothing for any
/// other daemon. `dry` (the probe before an update) only checks the plan.
/// It refuses (exit 3, [`REFUSED`]) before changing anything; once it
/// changed something it prints [`MIGRATING`] and ends the script, with
/// [`SYSTEMD_STARTED`] when `acpmux.service` started. A second run finds the
/// daemon under `acpmux.service` and does nothing.
pub(super) fn migrate(dry: bool) -> String {
    let apply = if dry {
        "rm -rf \"$t\"; exit 0\n".to_owned()
    } else {
        format!(
            "{SYSTEMD_LINGERING} || refuse noLinger \"this user's systemd manager does not linger, so acpmux.service would stop at logout: run loginctl enable-linger, then run this again\"\n{MIGRATE_STOP}{STILL_RUNNING_CHECK}\n{MIGRATE_START}echo {SYSTEMD_STARTED}; exit 0\n"
        )
    };
    format!(
        "if [ -n \"$u\" ] && [ \"$u\" != acpmux.service ]; then\ndh={REMOTE_HOME}\n{MIGRATE_PLAN}cat > \"$t/acpmux.service\" <<'ACPMUX_UNIT'\n{SYSTEMD_UNIT}ACPMUX_UNIT\n{MIGRATE_CONFLICTS}{apply}fi\n"
    )
}

/// Moves the daemon back to the hand-written `unit` and puts the previous
/// binary back; None for a unit name that is not plain.
pub(super) fn migrate_back(unit: &str) -> Option<String> {
    let plain = unit.ends_with(".service")
        && unit.bytes().all(|b| b.is_ascii_alphanumeric() || b"@._-".contains(&b));
    plain.then(|| format!("u={unit}\n{RESTORE_PREV}\n{MIGRATE_BACK}"))
}
