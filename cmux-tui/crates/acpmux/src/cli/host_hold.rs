//! `acpmux host hold`: machines `host update` leaves alone. A hold names a
//! peer (or its ssh host) that is not this person's to update now, such as
//! a machine reserved for someone else or one someone else runs: `host
//! update` answers `held` for it without reaching it over ssh, so its daemon
//! is never restarted, and the app's update queue shows nothing for it. A
//! hold may end by itself (`--until`). Holds live in
//! `~/.acpmux/update-holds.json`, the person's own home whatever
//! `ACPMUX_HOME` a daemon runs on: they are about machines, not one daemon.
//! Whatever knows about reservations (fleet tooling) writes them with this
//! command. A change is one locked read-modify-write (`update-holds.lock`)
//! and one rename, so two commands never lose each other's hold and a
//! reader sees the file whole.

use crate::cli::output::print_json;
use anyhow::{Context, Result, anyhow};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::collections::BTreeMap;
use std::io::Read;
use std::path::{Path, PathBuf};

/// A holds file is a few hundred bytes; one past this is refused.
const HOLDS_MAX_BYTES: u64 = 1024 * 1024;

/// `update-holds.json`: one hold per machine, by peer name or ssh host,
/// lowercased.
#[derive(Debug, Default, Serialize, Deserialize, PartialEq)]
pub(crate) struct Holds {
    #[serde(default)]
    pub(crate) holds: BTreeMap<String, Hold>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub(crate) struct Hold {
    /// Why, as whoever held it said (`reserved for a teammate`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) reason: Option<String>,
    /// When the hold ends by itself (RFC 3339); None: until it is released.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) until: Option<String>,
}

/// `~/.acpmux/update-holds.json`.
pub(crate) fn holds_path() -> PathBuf {
    crate::config::default_home().join("update-holds.json")
}

/// Now, in ms since the epoch.
pub(crate) fn now_ms() -> u64 {
    let since = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH);
    since.map_or(0, |d| d.as_millis() as u64)
}

impl Holds {
    /// The holds in `path`, none when it does not exist in a folder that
    /// does (or when there is no such folder at all). A file that cannot be
    /// read, or a folder that is a dangling link or no folder, is an error: a
    /// hold is never dropped on a guess. It is read as state of this user's
    /// (`config::private_state_file`: no link, owned by this user, not
    /// writable by others), at most [`HOLDS_MAX_BYTES`].
    pub(crate) fn read(path: &Path) -> Result<Holds> {
        match std::fs::symlink_metadata(path) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                let dir = path.parent().unwrap_or(Path::new("."));
                return match (std::fs::symlink_metadata(dir), std::fs::metadata(dir)) {
                    (Err(e), _) if e.kind() == std::io::ErrorKind::NotFound => Ok(Holds::default()),
                    (_, Ok(m)) if m.is_dir() => Ok(Holds::default()),
                    _ => Err(anyhow!(
                        "{}: its folder {} is not a folder (a dangling link?), so its holds \
                         cannot be read",
                        path.display(),
                        dir.display()
                    )),
                };
            }
            Err(e) => return Err(e).with_context(|| format!("read {}", path.display())),
            Ok(_) => {}
        }
        let file = crate::config::private_state_file(path)?;
        let mut bytes = Vec::new();
        file.take(HOLDS_MAX_BYTES + 1)
            .read_to_end(&mut bytes)
            .with_context(|| format!("read {}", path.display()))?;
        anyhow::ensure!(
            bytes.len() as u64 <= HOLDS_MAX_BYTES,
            "{} is larger than {HOLDS_MAX_BYTES} bytes",
            path.display()
        );
        serde_json::from_slice(&bytes)
            .with_context(|| format!("{} is not an update-holds file", path.display()))
    }

    fn write(&self, path: &Path) -> Result<()> {
        if let Some(dir) = path.parent() {
            crate::config::private_state_dir(dir)?;
        }
        let mut text = serde_json::to_string_pretty(self)?;
        text.push('\n');
        crate::config::write_atomic(path, text.as_bytes())
    }

    /// Why peer `name`, at ssh host `host` (`[user@]host`), is held at
    /// `now` (ms), None when it is not. A hold names the peer, its host or
    /// the host's first label, in any case; any of them that holds counts.
    /// One whose `until` passed holds nothing; one whose `until` cannot be
    /// read still holds.
    pub(crate) fn why(&self, name: &str, host: &str, now: u64) -> Option<String> {
        let host = host.rsplit('@').next().unwrap_or(host).to_ascii_lowercase();
        let short = host.split('.').next().unwrap_or(&host).to_owned();
        let names = [name.to_ascii_lowercase(), host, short];
        let active = |hold: &Hold| {
            let end = hold.until.as_deref().and_then(crate::server::machine_health::rfc3339_ms);
            end.is_none_or(|end| end > now)
        };
        let (key, hold) = self
            .holds
            .iter()
            .find(|(key, hold)| names.contains(&key.to_ascii_lowercase()) && active(hold))?;
        let mut why = format!("{key} is held");
        if let Some(reason) = &hold.reason {
            why.push_str(&format!(" ({reason})"));
        }
        if let Some(until) = &hold.until {
            why.push_str(&format!(" until {until}"));
        }
        why.push_str(&format!(
            ", so host update leaves it alone (`acpmux host hold {key} --release` ends it)"
        ));
        Some(why)
    }
}

/// An exclusive lock on the holds next to `path` (`File::lock`: flock on
/// Unix, LockFileEx on Windows), held while it lives: one read-modify-write
/// at a time. One that cannot be taken is an error: nothing is written
/// unlocked.
fn lock_holds(path: &Path) -> Result<std::fs::File> {
    let lock = path.with_extension("lock");
    if let Some(dir) = lock.parent() {
        crate::config::private_state_dir(dir)?;
    }
    let file = crate::config::private_state_rw(&lock)?;
    file.lock().with_context(|| format!("lock {}", lock.display()))?;
    Ok(file)
}

/// `host hold [NAME] [--reason TEXT] [--until TIME] [--release]`: hold
/// NAME, release it, or with no NAME list the holds.
pub(crate) fn hold(
    name: Option<String>,
    reason: Option<String>,
    until: Option<String>,
    release: bool,
    json_out: bool,
) -> Result<()> {
    change(&holds_path(), name, reason, until, release, json_out)
}

/// [`hold`] on the holds file `path`.
fn change(
    path: &Path,
    name: Option<String>,
    reason: Option<String>,
    until: Option<String>,
    release: bool,
    json_out: bool,
) -> Result<()> {
    let Some(name) = name.map(|n| n.trim().to_ascii_lowercase()) else {
        let holds = Holds::read(path)?;
        if json_out {
            print_json(&json!({"holds": holds.holds, "file": path}));
        } else {
            for (name, hold) in &holds.holds {
                let reason = hold.reason.as_deref().unwrap_or("");
                let until = hold.until.as_deref().unwrap_or("released by hand");
                println!("{name:<20} {until:<26} {reason}");
            }
        }
        return Ok(());
    };
    anyhow::ensure!(
        !name.is_empty() && !name.starts_with('-') && !name.chars().any(char::is_whitespace),
        "{name:?} is not a machine name"
    );
    if let Some(until) = &until
        && crate::server::machine_health::rfc3339_ms(until).is_none()
    {
        return Err(anyhow!("--until {until}: not an RFC 3339 time (2026-10-28T23:59:59Z)"));
    }
    let _lock = lock_holds(path)?;
    let mut holds = Holds::read(path)?;
    if release {
        let before = holds.holds.len();
        holds.holds.retain(|key, _| !key.eq_ignore_ascii_case(&name));
        let known = holds.holds.len() != before;
        holds.write(path)?;
        if json_out {
            print_json(&json!({"released": name, "held": known}));
        } else if known {
            println!("{name}: released; host update reaches it again");
        } else {
            println!("{name}: was not held");
        }
        return Ok(());
    }
    let hold = Hold { reason, until };
    holds.holds.retain(|key, _| !key.eq_ignore_ascii_case(&name));
    holds.holds.insert(name.clone(), hold.clone());
    holds.write(path)?;
    if json_out {
        print_json(&json!({"held": name, "hold": hold}));
    } else {
        println!("{name}: held; host update leaves it alone");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: u64 = 1_793_000_000_000; // 2026-10-26

    fn holds(entries: &[(&str, Option<&str>, Option<&str>)]) -> Holds {
        let holds = entries
            .iter()
            .map(|(k, reason, until)| {
                let hold = Hold { reason: reason.map(Into::into), until: until.map(Into::into) };
                ((*k).to_owned(), hold)
            })
            .collect();
        Holds { holds }
    }

    #[test]
    fn a_hold_names_the_peer_its_host_or_the_hosts_first_label() {
        let h = holds(&[("mini-a", Some("reserved for a teammate"), None)]);
        assert!(h.why("mini-a", "elsewhere", NOW).is_some(), "the peer name");
        assert!(h.why("other", "cmux@Mini-A.tail0.ts.net", NOW).is_some(), "the first label");
        assert!(h.why("other", "mini-a", NOW).is_some(), "the host");
        assert_eq!(h.why("mini-b", "mini-b.tail0.ts.net", NOW), None);
        let why = h.why("mini-a", "mini-a", NOW).unwrap();
        assert!(why.contains("(reserved for a teammate)"), "{why}");
        assert!(why.contains("acpmux host hold mini-a --release"), "{why}");
        let fqdn = holds(&[("mini-a.tail0.ts.net", None, None)]);
        assert!(fqdn.why("x", "cmux@mini-a.tail0.ts.net", NOW).is_some());
    }

    #[test]
    fn an_expired_hold_under_one_name_never_hides_an_active_one_under_another() {
        let h = holds(&[
            ("mini-a", None, Some("2026-10-01T00:00:00Z")),
            ("mini-a.tail0.ts.net", Some("reserved"), Some("2026-10-28T23:59:59Z")),
        ]);
        let why = h.why("mini-a", "cmux@mini-a.tail0.ts.net", NOW).unwrap();
        assert!(why.starts_with("mini-a.tail0.ts.net is held (reserved)"), "{why}");
    }

    #[test]
    fn a_hold_ends_at_its_until_and_an_unreadable_one_still_holds() {
        let h = holds(&[
            ("past", None, Some("2026-10-01T00:00:00Z")),
            ("future", None, Some("2026-10-28T23:59:59Z")),
            ("garbled", None, Some("next week")),
        ]);
        assert_eq!(h.why("past", "past", NOW), None);
        assert!(h.why("future", "future", NOW).unwrap().contains("until 2026-10-28T23:59:59Z"));
        assert!(h.why("garbled", "garbled", NOW).is_some());
    }

    fn scratch(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("acpmux-holds-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        dir
    }

    #[test]
    fn the_file_reads_back_and_a_missing_one_holds_nothing() {
        let dir = scratch("file");
        let path = dir.join("update-holds.json");
        assert_eq!(Holds::read(&path).unwrap(), Holds::default());
        let h = holds(&[("mini-a", Some("r"), Some("2026-10-28T23:59:59Z"))]);
        h.write(&path).unwrap();
        assert_eq!(Holds::read(&path).unwrap(), h);
        std::fs::write(&path, "not json").unwrap();
        assert!(Holds::read(&path).is_err(), "never dropped on a guess");
        std::fs::write(&path, vec![b' '; HOLDS_MAX_BYTES as usize + 1]).unwrap();
        assert!(Holds::read(&path).is_err(), "bounded");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    #[cfg(unix)]
    fn a_holds_file_through_a_link_or_writable_by_others_is_refused() {
        use std::os::unix::fs::PermissionsExt;
        let dir = scratch("link");
        let path = dir.join("update-holds.json");
        holds(&[("mini-a", None, None)]).write(&path).unwrap();
        let link = dir.join("linked.json");
        std::os::unix::fs::symlink(&path, &link).unwrap();
        assert!(Holds::read(&link).is_err(), "a link is refused");
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o666)).unwrap();
        assert!(Holds::read(&path).is_err(), "writable by others is refused");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn hold_and_release_change_one_name_and_keep_the_others() {
        let dir = scratch("change");
        let path = dir.join("update-holds.json");
        let until = Some("2026-10-28T23:59:59Z".to_owned());
        change(&path, Some("Mini-A".into()), Some("r".into()), until, false, true).unwrap();
        change(&path, Some("mini-b".into()), None, None, false, true).unwrap();
        let read = Holds::read(&path).unwrap();
        assert_eq!(read.holds.keys().collect::<Vec<_>>(), ["mini-a", "mini-b"]);
        change(&path, Some("MINI-A".into()), None, None, true, true).unwrap();
        let read = Holds::read(&path).unwrap();
        assert_eq!(read.holds.keys().collect::<Vec<_>>(), ["mini-b"]);
        let bad = Some("next week".to_owned());
        assert!(change(&path, Some("mini-c".into()), None, bad, false, true).is_err());
        assert!(change(&path, Some("--all".into()), None, None, false, true).is_err());
        assert_eq!(Holds::read(&path).unwrap().holds.len(), 1, "a refused change writes nothing");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A folder that is a dangling link hides nothing: the read fails, so
    /// `host update` leaves the peer alone (`holdsUnreadable`).
    #[test]
    #[cfg(unix)]
    fn a_holds_folder_that_is_a_dangling_link_is_an_error_not_no_holds() {
        let dir = scratch("dangling");
        std::fs::create_dir_all(&dir).unwrap();
        let home = dir.join("home");
        std::os::unix::fs::symlink(dir.join("gone"), &home).unwrap();
        assert!(Holds::read(&home.join("update-holds.json")).is_err());
        let file = dir.join("file");
        std::fs::write(&file, "").unwrap();
        assert!(Holds::read(&file.join("update-holds.json")).is_err(), "not a folder");
        let none = dir.join("no-home").join("update-holds.json");
        assert_eq!(Holds::read(&none).unwrap(), Holds::default(), "no home at all: nothing held");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Two commands at once never lose each other's hold.
    #[test]
    fn concurrent_holds_are_all_kept() {
        let dir = scratch("race");
        let path = dir.join("update-holds.json");
        std::thread::scope(|s| {
            for i in 0..8 {
                let path = &path;
                s.spawn(move || change(path, Some(format!("m{i}")), None, None, false, true));
            }
        });
        assert_eq!(Holds::read(&path).unwrap().holds.len(), 8);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
