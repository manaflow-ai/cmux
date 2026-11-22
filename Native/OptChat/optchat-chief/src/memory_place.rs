//! How the Chief's memory follows it to another machine: over a projected folder (RFD 0007,
//! `projection-v1`) when the machine serves one, so the new machine reads the memory from the
//! old one without a copy made first; else, as before, `optchat-chief memory export/import`
//! (or a `move` checkpoint).
//!
//! Leo, 2026-11-22: "chief in cloud. likely under our projection protocol or something, since it
//! has some semblance of memory or whatever, but they may be sized with their own vms."
//!
//! The memory is `memory.sqlite3` (log, tree, host state) and `memory-files.sqlite3` (notes,
//! rules, open loops). The projection carries a consistent snapshot of both; the live stores, with
//! their WAL and `-shm`, always stay on the local disk of the machine that writes them. SQLite on
//! the FUSE mount itself is not covered by the projection's tests (byte-range locks, a shared
//! writable mmap of `-shm`), so the memory is never opened there.
//!
//! The steps of a move from machine A to machine B:
//!
//! 1. **Hand out** on A (`optchat-chief memory hand-out --to MACHINE DIR`, host stopped): under
//!    the host lock, `VACUUM INTO` a consistent copy of each store into `DIR` (never the live file
//!    with its WAL), then `writer.json` last (epoch + 1, the one machine that may write it, each
//!    file's sha256 and row counts), then A's home is marked moved (`state/moved.json`), so A's
//!    host refuses to start. A crash before `writer.json` leaves no hand-out and A the writer.
//! 2. **Project** `DIR` at B's `optchat/memory/` under the name [`projection_name`] (`cmux link
//!    project serve --socket S --at REMOTE --name NAME DIR`, the merged `projection.serve` dial;
//!    `hand-out --socket S --at REMOTE` starts it). B reads it; nothing is written there.
//! 3. **Take in** on B, by the host itself at its first start (or `memory take-in`): the folder
//!    must be a mount, `writer.json` must name this machine at an epoch above any this home took
//!    in before. Each store is copied byte for byte off the mount into `optchat/` beside a temp
//!    name, fsynced, checked against the hand-out's sha256 and row counts, and only then renamed
//!    over; a plain memory already there is kept as `NAME.before-take-in-EPOCH`. Then
//!    `optchat/memory-place.json` (machine-local) records the epoch. From then on B never needs
//!    A or the mount: `cmux link project stop` ends it.
//!
//! One writer at a time, and what enforces it:
//! - A projection never writes back to its source, and nothing writes the mount: B's memory is
//!   B's own files, so no two machines ever write the same bytes; a second writer could only fork
//!   the memory, and these rules keep a fork from starting.
//! - The source stops being a writer before the hand-out exists: the host lock (flock) is held
//!   for the whole hand-out and `state/moved.json` is written before it is released, which the
//!   host already refuses to start on (`migrate::refusal`).
//! - Only the machine `writer.json` names takes the memory in, once per epoch: a third machine
//!   that mounts the same hand-out refuses it, and so does a machine that took this or a later
//!   epoch already.
//! - On one machine, the host lock (flock on `state/host.lock`) keeps a second host off the home.
//!
//! No loss when the machine dies mid-write: the live memory is plain SQLite on the local disk (WAL,
//! `synchronous=FULL`), as on any Chief. A death mid-take-in leaves either the old file or the
//! whole checked copy at each name (a rename after an fsync) and no record, so the next start
//! takes the same hand-out in again. A machine destroyed, not restarted, loses what it wrote since
//! its take-in: the projection does not bring writes back, so the per-turn remote backup
//! (`backup.rs`) and `memory export` are what keep those.
//!
//! Going back: hand the memory out again from B to A (a later epoch) and run `optchat-chief memory
//! take-in` on A, which also lifts A's `projected:` moved mark; or, if B never wrote, `optchat-chief
//! move rollback` on A.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

/// The daemon capability that mounts a projected folder (cmux-tui-core `projection.rs`).
pub const CAPABILITY: &str = "projection-v1";
/// The folder under `optchat/` a hand-out is mounted at.
pub const FOLDER: &str = "memory";
/// The hand-out's marker, written last into the folder.
pub const WRITER_FILE: &str = "writer.json";
/// This machine's record of the last hand-out it took in (never carried by a move).
pub const RECORD_FILE: &str = "memory-place.json";
/// The stores that are the memory, by file name.
pub const STORES: [&str; 2] = ["memory.sqlite3", crate::memory_files::FILE];
/// The env switch projected folders share (`0`/`false` turns them off).
const ENV: &str = "CMUX_PROJECTED_FOLDERS";
/// What the record's `place` says.
const TAKEN_IN: &str = "taken-in";
/// The moved mark a hand-out leaves on its source.
const MOVED_PREFIX: &str = "projected:";

/// The fallback steps when the memory cannot be projected.
pub const FALLBACK: &str = "move the memory with `optchat-chief memory export --text DIR` on the \
     old machine and `optchat-chief memory import DIR` on the new one (or `optchat-chief move`)";

/// `writer.json`: the hand-out of one epoch of the memory to one machine.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Writer {
    /// One more than the epoch the source took in last (0 for a memory never projected).
    pub epoch: u64,
    /// The one machine that may take it in and write it ([`machine_id`]).
    pub to: String,
    /// The machine it was handed out from.
    pub from: String,
    /// The home's id (`optchat/home-id`), the same on both sides.
    pub home_id: String,
    pub at: String,
    /// Per store: its sha256 and its tables' row counts.
    pub files: BTreeMap<String, Store>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Store {
    pub sha256: String,
    pub bytes: u64,
    pub rows: BTreeMap<String, u64>,
}

/// `optchat/memory-place.json`: this machine took the hand-out of `epoch` in.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Record {
    pub place: String,
    pub epoch: u64,
    pub name: String,
    pub from: String,
    pub at: String,
}

/// What a start knows about the memory's place.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Inputs {
    /// The daemon advertised [`CAPABILITY`].
    pub capability: bool,
    /// Projected folders are not turned off ([`ENV`]).
    pub enabled: bool,
    /// This machine's record of the last hand-out it took in.
    pub record: Option<Record>,
    /// `optchat/memory/` is a mount.
    pub mounted: bool,
    /// The folder's `writer.json`, when readable.
    pub writer: Option<Writer>,
    /// This machine ([`machine_id`]).
    pub machine: String,
    /// `optchat/memory.sqlite3` exists.
    pub local_memory: bool,
}

/// What this start does about the memory.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Choice {
    /// A hand-out to this machine is mounted and newer than any it took in: take it in.
    TakeIn(Writer),
    /// The memory is this machine's files under `optchat/` (taken in before, or never moved).
    /// `fallback` says why a move would not go over a projection and how it goes instead, when
    /// that is so (no capability, turned off).
    Local { fallback: Option<String> },
    /// Do not start: the mounted memory is not this machine's to write.
    Refuse(String),
}

/// The pure rule: what to do about the memory, from what a start knows.
pub fn choose(inputs: &Inputs) -> Choice {
    let projectable = inputs.capability && inputs.enabled;
    let taken = inputs.record.as_ref().map(|r| r.epoch);
    let fallback = if !inputs.capability {
        Some(format!(
            "this machine does not serve {CAPABILITY}: {FALLBACK}"
        ))
    } else if !inputs.enabled {
        Some(format!("projected folders are off ({ENV}=0): {FALLBACK}"))
    } else {
        None
    };
    if !inputs.mounted {
        return Choice::Local { fallback };
    }
    match &inputs.writer {
        Some(w) if w.to == inputs.machine && taken.is_some_and(|t| w.epoch <= t) => {
            // Taken in already (or older): the memory is local; the mount is only stale.
            Choice::Local { fallback }
        }
        Some(w) if w.to == inputs.machine && projectable => Choice::TakeIn(w.clone()),
        Some(w) if w.to == inputs.machine => Choice::Refuse(format!(
            "a memory hand-out is mounted here but {}: not taking it",
            fallback.unwrap_or_default()
        )),
        Some(w) => Choice::Refuse(format!(
            "the mounted memory is handed to {} at epoch {}, not to this machine ({}): not taking it",
            w.to, w.epoch, inputs.machine
        )),
        None => Choice::Refuse(format!(
            "optchat/{FOLDER} is a mount without {WRITER_FILE}: not a memory hand-out"
        )),
    }
}

/// The projection's name for `home_id`'s memory at `epoch`. The epoch keeps a later hand-out
/// from attaching to the upper layer an earlier one left on the machine.
pub fn projection_name(home_id: &str, epoch: u64) -> String {
    format!("chief-memory-{home_id}-e{epoch}")
}

/// `optchat/memory/` of the home whose optchat root is `root`.
pub fn folder(root: &Path) -> PathBuf {
    root.join(FOLDER)
}

/// The record of the last hand-out this machine took in.
pub fn record(root: &Path) -> Option<Record> {
    let text = std::fs::read_to_string(root.join(RECORD_FILE)).ok()?;
    serde_json::from_str::<Record>(&text)
        .ok()
        .filter(|r| r.place == TAKEN_IN)
}

/// The folder's `writer.json`.
pub fn read_writer(dir: &Path) -> Option<Writer> {
    let text = std::fs::read_to_string(dir.join(WRITER_FILE)).ok()?;
    serde_json::from_str(&text).ok()
}

/// Whether projected folders are on (the env switch only; the setting file is cmux's).
pub fn enabled() -> bool {
    match crate::cli::env(ENV).as_deref().map(str::trim) {
        Some("0" | "false" | "off") => false,
        _ => true,
    }
}

/// This machine's id: `OPTCHAT_MACHINE_ID`, else `/etc/machine-id`, else its host name.
pub fn machine_id() -> String {
    if let Some(id) = crate::cli::env("OPTCHAT_MACHINE_ID") {
        return id;
    }
    std::fs::read_to_string("/etc/machine-id")
        .ok()
        .map(|s| s.trim().to_owned())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(crate::migrate::hostname)
}

/// Whether `at` is a FUSE mount point (Linux `/proc/self/mountinfo`; never elsewhere).
pub fn is_fuse_mount(at: &Path) -> bool {
    let Ok(at) = at.canonicalize() else {
        return false;
    };
    let Ok(info) = std::fs::read_to_string("/proc/self/mountinfo") else {
        return false;
    };
    mountinfo_has_fuse(&info, &at)
}

/// Whether `mountinfo` lists a FUSE mount at `at`.
fn mountinfo_has_fuse(mountinfo: &str, at: &Path) -> bool {
    let want = at.to_string_lossy();
    mountinfo.lines().any(|line| {
        let fields: Vec<&str> = line.split(' ').collect();
        let Some(dash) = fields.iter().position(|f| *f == "-") else {
            return false;
        };
        let point = fields.get(4).map(|p| unescape_mount(p));
        let fstype = fields.get(dash + 1).copied().unwrap_or_default();
        point.as_deref() == Some(want.as_ref()) && (fstype == "fuse" || fstype.starts_with("fuse."))
    })
}

/// mountinfo's octal escapes (`\040` for a space).
fn unescape_mount(field: &str) -> String {
    let bytes = field.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'\\'
            && i + 3 < bytes.len()
            && let Ok(n) = u8::from_str_radix(&field[i + 1..i + 4], 8)
        {
            out.push(n);
            i += 4;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// What a start of the home at `root` knows, with `capability` from the daemon.
pub fn inputs(root: &Path, capability: bool) -> Inputs {
    let dir = folder(root);
    let mounted = is_fuse_mount(&dir) || crate::cli::env("OPTCHAT_MEMORY_MOUNT_ASSUMED").is_some();
    Inputs {
        capability,
        enabled: enabled(),
        record: record(root),
        mounted,
        writer: if mounted { read_writer(&dir) } else { None },
        machine: machine_id(),
        local_memory: root.join(STORES[0]).exists(),
    }
}

/// Whether the session daemon at `socket` advertises [`CAPABILITY`]; None when it cannot be
/// asked.
pub fn daemon_capability(socket: &Path) -> Option<bool> {
    use cmux::raw::{Client, ClientConfig};
    let mut client = Client::connect(ClientConfig::from_socket_path(socket)).ok()?;
    let caps = client
        .identify_server()
        .ok()?
        .capabilities
        .unwrap_or_default();
    Some(caps.iter().any(|c| c == CAPABILITY))
}

/// The start's step, before anything opens the memory: takes a mounted hand-out in, or says why
/// the host must not start. Returns a line to log, or the refusal.
pub fn at_host_start(home: &Path, capability: bool) -> Result<String, String> {
    let root = crate::paths::Paths::new(home).root;
    let inputs = inputs(&root, capability);
    match choose(&inputs) {
        Choice::TakeIn(w) => {
            let record = take_in(home, &w)?;
            Ok(format!(
                "memory: took in the hand-out from {} (epoch {}, projection {}); `cmux link project stop --at {}` ends the projection",
                w.from,
                record.epoch,
                record.name,
                folder(&root).display()
            ))
        }
        Choice::Local { fallback } => Ok(match (inputs.record, fallback) {
            (Some(r), _) => format!(
                "memory: plain files, taken in from {} at epoch {}",
                r.from, r.epoch
            ),
            (None, Some(why)) => format!("memory: plain files; {why}"),
            (None, None) => "memory: plain files".to_owned(),
        }),
        Choice::Refuse(why) => Err(why),
    }
}

fn store_of(path: &Path) -> Result<Store, String> {
    let (sha256, bytes) = crate::migrate::sha256_file(path)?;
    let rows = crate::migrate::table_counts(path)?;
    Ok(Store {
        sha256,
        bytes,
        rows,
    })
}

fn write_atomic(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let tmp = path.with_extension(format!("tmp-{}", std::process::id()));
    crate::migrate::write_private(&tmp, bytes)?;
    std::fs::File::open(&tmp)
        .and_then(|f| f.sync_all())
        .map_err(|e| format!("{}: {e}", tmp.display()))?;
    std::fs::rename(&tmp, path).map_err(|e| format!("renaming {}: {e}", path.display()))?;
    sync_dir(path.parent().unwrap_or(Path::new(".")));
    Ok(())
}

fn sync_dir(dir: &Path) {
    if let Ok(dir) = std::fs::File::open(dir) {
        let _ = dir.sync_all();
    }
}

/// Hands the memory of the home at `home` out into `out` for machine `to`. The caller holds
/// the host lock (no host writes the memory meanwhile). On success the home is marked moved.
pub fn hand_out(home: &Path, to: &str, out: &Path) -> Result<Writer, String> {
    if to.trim().is_empty() {
        return Err("hand-out needs --to MACHINE (the target's /etc/machine-id)".into());
    }
    // One writer: a home already handed out (or moved, or moving) is not the writer, and a
    // second hand-out from it would give the same epoch to two machines.
    if let Some(why) = crate::migrate::refusal(home) {
        return Err(format!("not handing out: {why}"));
    }
    let root = crate::paths::Paths::new(home).root;
    crate::migrate::create_private_dir(out)?;
    if std::fs::read_dir(out)
        .map_err(|e| format!("{}: {e}", out.display()))?
        .next()
        .is_some()
    {
        return Err(format!("{} is not empty", out.display()));
    }
    let epoch = record(&root).map_or(0, |r| r.epoch) + 1;
    let mut files = BTreeMap::new();
    for name in STORES {
        let from = root.join(name);
        if !from.exists() {
            continue;
        }
        let to_file = out.join(name);
        crate::migrate::vacuum_into(&from, &to_file)?;
        std::fs::File::open(&to_file)
            .and_then(|f| f.sync_all())
            .map_err(|e| format!("{}: {e}", to_file.display()))?;
        files.insert(name.to_owned(), store_of(&to_file)?);
    }
    if !files.contains_key(STORES[0]) {
        return Err(format!("no memory at {}", root.join(STORES[0]).display()));
    }
    let writer = Writer {
        epoch,
        to: to.to_owned(),
        from: machine_id(),
        home_id: crate::paths::home_id(home),
        at: crate::migrate::now_rfc3339(),
        files,
    };
    let text = serde_json::to_string_pretty(&writer).map_err(|e| e.to_string())?;
    // Last: a hand-out without its writer.json is no hand-out.
    write_atomic(&out.join(WRITER_FILE), text.as_bytes())?;
    crate::migrate::mark_moved(
        home,
        &format!("{MOVED_PREFIX}{to}"),
        &writer.files[STORES[0]].sha256,
    )?;
    Ok(writer)
}

/// Copies `from` (on the mount) to `to` byte for byte and fsyncs it.
fn copy_synced(from: &Path, to: &Path) -> Result<(), String> {
    let mut src =
        std::fs::File::open(from).map_err(|e| format!("reading {}: {e}", from.display()))?;
    let mut dst = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(to)
        .map_err(|e| format!("{}: {e}", to.display()))?;
    std::io::copy(&mut src, &mut dst).map_err(|e| format!("copying {}: {e}", from.display()))?;
    dst.sync_all()
        .map_err(|e| format!("syncing {}: {e}", to.display()))
}

/// Removes a temp copy and the SQLite side files checking it may have left.
fn remove_temp(tmp: &Path) {
    for suffix in ["", "-wal", "-shm", "-journal"] {
        let mut p = tmp.as_os_str().to_owned();
        p.push(suffix);
        let _ = std::fs::remove_file(PathBuf::from(p));
    }
}

/// Takes the mounted hand-out `writer` in on the home at `home`: every store is copied off the
/// mount to a temp file, fsynced and checked against the hand-out, then renamed into place (a
/// different plain memory already there is kept beside it); then the record is written, and a
/// `projected:` moved mark this home carries from its own earlier hand-out is lifted.
pub fn take_in(home: &Path, writer: &Writer) -> Result<Record, String> {
    let root = crate::paths::Paths::new(home).root;
    let dir = folder(&root);
    let mut placed = Vec::new();
    for (name, want) in &writer.files {
        let tmp = root.join(format!("{name}.tmp-take-in"));
        remove_temp(&tmp);
        copy_synced(&dir.join(name), &tmp).inspect_err(|_| remove_temp(&tmp))?;
        let got = store_of(&tmp);
        remove_temp_sides(&tmp);
        let got = got.inspect_err(|_| remove_temp(&tmp))?;
        if got.sha256 != want.sha256 || got.rows != want.rows {
            remove_temp(&tmp);
            return Err(format!(
                "{name} in the projected folder does not match its hand-out (sha256 {} rows {:?}, want {} {:?})",
                got.sha256, got.rows, want.sha256, want.rows
            ));
        }
        placed.push((name.clone(), tmp, want.sha256.clone()));
    }
    for (name, tmp, sha) in placed {
        let to = root.join(&name);
        // A WAL holds rows the main file does not show yet, so a file with one is never "the same".
        let has_wal = std::fs::metadata(side(&to, "-wal")).is_ok_and(|m| m.len() > 0);
        let same = !has_wal && crate::migrate::sha256_file(&to).is_ok_and(|(s, _)| s == sha);
        if to.exists() && !same {
            let mut kept = root.join(format!("{name}.before-take-in-{}", writer.epoch));
            if kept.exists() {
                kept = root.join(format!(
                    "{name}.before-take-in-{}-{}",
                    writer.epoch,
                    std::process::id()
                ));
            }
            // Its side files go with it: a crashed host's last rows are in its WAL.
            for suffix in ["-wal", "-shm", "-journal"] {
                let from = side(&to, suffix);
                if from.exists() {
                    std::fs::rename(&from, side(&kept, suffix))
                        .map_err(|e| format!("keeping {}: {e}", from.display()))?;
                }
            }
            std::fs::rename(&to, &kept).map_err(|e| format!("keeping {}: {e}", to.display()))?;
        }
        // Side files left now belong to a file identical to the one placed.
        remove_temp_sides(&to);
        std::fs::rename(&tmp, &to).map_err(|e| format!("placing {}: {e}", to.display()))?;
    }
    sync_dir(&root);
    let record = Record {
        place: TAKEN_IN.into(),
        epoch: writer.epoch,
        name: projection_name(&writer.home_id, writer.epoch),
        from: writer.from.clone(),
        at: crate::migrate::now_rfc3339(),
    };
    let text = serde_json::to_string_pretty(&record).map_err(|e| e.to_string())?;
    write_atomic(&root.join(RECORD_FILE), text.as_bytes())?;
    if crate::migrate::moved(home).is_some_and(|m| m.to.starts_with(MOVED_PREFIX)) {
        std::fs::remove_file(home.join(crate::migrate::MOVED_FILE))
            .map_err(|e| format!("lifting this home's moved mark: {e}"))?;
        sync_dir(&home.join("state"));
    }
    Ok(record)
}

/// Removes the SQLite side files of `db` (never `db` itself).
/// `db` with a SQLite side-file suffix (`-wal`, `-shm`, `-journal`).
fn side(db: &Path, suffix: &str) -> PathBuf {
    let mut p = db.as_os_str().to_owned();
    p.push(suffix);
    PathBuf::from(p)
}

fn remove_temp_sides(db: &Path) {
    for suffix in ["-wal", "-shm", "-journal"] {
        let mut p = db.as_os_str().to_owned();
        p.push(suffix);
        let _ = std::fs::remove_file(PathBuf::from(p));
    }
}

/// A one-line status of the memory's place.
pub fn status(root: &Path, capability: Option<bool>) -> String {
    let inputs = inputs(root, capability.unwrap_or(false));
    let cap = match capability {
        Some(true) => format!("serves {CAPABILITY}"),
        Some(false) => format!("does not serve {CAPABILITY}"),
        None => format!("{CAPABILITY} not asked (no daemon)"),
    };
    let place = match choose(&inputs) {
        Choice::TakeIn(w) => format!(
            "a hand-out (epoch {}) from {} is mounted, not taken in yet",
            w.epoch, w.from
        ),
        Choice::Local { fallback } => {
            let mut line = format!("plain files under {}", root.display());
            if let Some(r) = &inputs.record {
                line.push_str(&format!(", taken in from {} at epoch {}", r.from, r.epoch));
            }
            match fallback {
                Some(why) => line.push_str(&format!("; {why}")),
                None => {
                    line.push_str("; `memory hand-out --to MACHINE` moves it over a projection")
                }
            }
            line
        }
        Choice::Refuse(why) => format!("not usable here: {why}"),
    };
    format!("memory: {place}\nmachine {}: {cap}", inputs.machine)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn writer(epoch: u64, to: &str) -> Writer {
        Writer {
            epoch,
            to: to.into(),
            from: "a".into(),
            home_id: "0123abcd".into(),
            at: "t".into(),
            files: BTreeMap::new(),
        }
    }

    fn rec(epoch: u64) -> Record {
        Record {
            place: TAKEN_IN.into(),
            epoch,
            name: projection_name("0123abcd", epoch),
            from: "a".into(),
            at: "t".into(),
        }
    }

    fn base() -> Inputs {
        Inputs {
            capability: true,
            enabled: true,
            machine: "b".into(),
            ..Inputs::default()
        }
    }

    #[test]
    fn no_capability_falls_back_to_export_import() {
        let choice = choose(&Inputs {
            capability: false,
            local_memory: true,
            ..base()
        });
        let Choice::Local {
            fallback: Some(why),
        } = choice
        else {
            panic!("{choice:?}")
        };
        assert!(
            why.contains(CAPABILITY)
                && why.contains("memory export")
                && why.contains("memory import")
        );
    }

    #[test]
    fn turned_off_falls_back() {
        let choice = choose(&Inputs {
            enabled: false,
            ..base()
        });
        assert!(matches!(choice, Choice::Local { fallback: Some(ref w) } if w.contains("off")));
    }

    #[test]
    fn existing_local_memory_stays_put_with_capability() {
        assert_eq!(
            choose(&Inputs {
                local_memory: true,
                ..base()
            }),
            Choice::Local { fallback: None }
        );
    }

    #[test]
    fn mounted_hand_out_to_this_machine_is_taken_in() {
        let w = writer(1, "b");
        let choice = choose(&Inputs {
            mounted: true,
            writer: Some(w.clone()),
            ..base()
        });
        assert_eq!(choice, Choice::TakeIn(w));
    }

    #[test]
    fn hand_out_to_another_machine_is_refused() {
        let choice = choose(&Inputs {
            mounted: true,
            writer: Some(writer(1, "c")),
            ..base()
        });
        assert!(matches!(choice, Choice::Refuse(ref w) if w.contains("not to this machine")));
    }

    #[test]
    fn mounted_without_capability_is_refused_not_taken() {
        let choice = choose(&Inputs {
            capability: false,
            mounted: true,
            writer: Some(writer(1, "b")),
            ..base()
        });
        assert!(matches!(choice, Choice::Refuse(ref w) if w.contains("memory export")));
    }

    #[test]
    fn a_taken_in_epoch_is_not_taken_again() {
        let choice = choose(&Inputs {
            record: Some(rec(2)),
            mounted: true,
            writer: Some(writer(2, "b")),
            local_memory: true,
            ..base()
        });
        assert_eq!(choice, Choice::Local { fallback: None });
    }

    #[test]
    fn a_later_epoch_is_taken_in_an_older_one_not() {
        let later = choose(&Inputs {
            record: Some(rec(2)),
            mounted: true,
            writer: Some(writer(3, "b")),
            ..base()
        });
        assert!(matches!(later, Choice::TakeIn(ref w) if w.epoch == 3));
        let older = choose(&Inputs {
            record: Some(rec(2)),
            mounted: true,
            writer: Some(writer(1, "b")),
            ..base()
        });
        assert!(matches!(older, Choice::Local { .. }), "{older:?}");
    }

    #[test]
    fn taken_in_needs_no_mount() {
        let choice = choose(&Inputs {
            record: Some(rec(1)),
            mounted: false,
            local_memory: true,
            ..base()
        });
        assert_eq!(choice, Choice::Local { fallback: None });
    }

    #[test]
    fn a_mount_without_writer_is_refused() {
        let choice = choose(&Inputs {
            mounted: true,
            ..base()
        });
        assert!(matches!(choice, Choice::Refuse(ref w) if w.contains(WRITER_FILE)));
    }

    #[test]
    fn projection_name_carries_the_epoch() {
        assert_ne!(projection_name("h", 1), projection_name("h", 2));
    }

    #[test]
    fn mountinfo_finds_fuse_mount_with_escaped_space() {
        let info = "36 35 0:30 / /home/u/mux\\040home/optchat/memory rw,nosuid - fuse.cmux-projection cmux rw\n\
                    37 35 0:31 / /home/u/other rw - ext4 /dev/sda1 rw\n";
        assert!(mountinfo_has_fuse(
            info,
            Path::new("/home/u/mux home/optchat/memory")
        ));
        assert!(!mountinfo_has_fuse(info, Path::new("/home/u/other")));
        assert!(!mountinfo_has_fuse(info, Path::new("/home/u/none")));
    }

    fn seed_memory(dir: &Path, rows: &[&str]) {
        std::fs::create_dir_all(dir).unwrap();
        let conn = rusqlite::Connection::open(dir.join(STORES[0])).unwrap();
        conn.execute_batch(
            "PRAGMA journal_mode=WAL; CREATE TABLE IF NOT EXISTS log(id INTEGER PRIMARY KEY, text TEXT);",
        )
        .unwrap();
        for row in rows {
            conn.execute("INSERT INTO log(text) VALUES (?1)", [row])
                .unwrap();
        }
    }

    fn count(db: &Path, like: &str) -> i64 {
        rusqlite::Connection::open(db)
            .unwrap()
            .query_row("SELECT count(*) FROM log WHERE text LIKE ?1", [like], |r| {
                r.get(0)
            })
            .unwrap()
    }

    /// Stands in for the projection: the hand-out's files at `root/memory`.
    fn project(out: &Path, root: &Path) {
        let dir = folder(root);
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        for entry in std::fs::read_dir(out).unwrap() {
            let entry = entry.unwrap();
            std::fs::copy(entry.path(), dir.join(entry.file_name())).unwrap();
        }
    }

    fn mounted(root: &Path, machine: &str) -> Inputs {
        Inputs {
            mounted: true,
            writer: read_writer(&folder(root)),
            record: record(root),
            machine: machine.into(),
            capability: true,
            enabled: true,
            local_memory: root.join(STORES[0]).exists(),
        }
    }

    /// A to B and back to A on one disk: a plain folder stands in for the mount (the FUSE mount
    /// is cmux-projection's; `measure/projected_memory_crash.sh` copies off a real one).
    #[test]
    fn hand_out_take_in_and_back_round_trip() {
        let t = tempfile::tempdir().unwrap();
        let a_home = t.path().join("a");
        let a = crate::paths::Paths::new(&a_home);
        a.create().unwrap();
        seed_memory(&a.root, &["remember the blue door", "second"]);
        let out = t.path().join("out1");
        let w = hand_out(&a_home, "machine-b", &out).unwrap();
        assert_eq!(w.epoch, 1);
        assert_eq!(w.files[STORES[0]].rows["log"], 2);
        // The source refuses to start now: one writer.
        assert!(crate::migrate::refusal(&a_home).is_some());
        // A second hand-out into the same folder is refused.
        assert!(hand_out(&a_home, "machine-b", &out).is_err());

        // Machine B.
        let b_home = t.path().join("b");
        let b = crate::paths::Paths::new(&b_home);
        b.create().unwrap();
        project(&out, &b.root);
        // A third machine refuses the same hand-out.
        assert!(matches!(
            choose(&mounted(&b.root, "machine-c")),
            Choice::Refuse(_)
        ));
        let Choice::TakeIn(w) = choose(&mounted(&b.root, "machine-b")) else {
            panic!()
        };
        take_in(&b_home, &w).unwrap();
        // The memory is B's own plain files: the mount can go.
        assert_eq!(b.memory_db, b.root.join(STORES[0]));
        std::fs::remove_dir_all(folder(&b.root)).unwrap();
        assert_eq!(count(&b.memory_db, "%blue door%"), 1);
        assert_eq!(
            choose(&Inputs {
                mounted: false,
                ..mounted(&b.root, "machine-b")
            }),
            Choice::Local { fallback: None }
        );
        // The same hand-out is not taken twice.
        project(&out, &b.root);
        assert!(matches!(
            choose(&mounted(&b.root, "machine-b")),
            Choice::Local { .. }
        ));

        // B writes, then hands the memory back to A at a later epoch.
        seed_memory(&b.root, &["written on b"]);
        let out2 = t.path().join("out2");
        let w2 = hand_out(&b_home, "machine-a", &out2).unwrap();
        assert_eq!(w2.epoch, 2);
        assert!(crate::migrate::refusal(&b_home).is_some());
        project(&out2, &a.root);
        let Choice::TakeIn(w2) = choose(&mounted(&a.root, "machine-a")) else {
            panic!()
        };
        take_in(&a_home, &w2).unwrap();
        assert_eq!(count(&a.memory_db, "written on b"), 1);
        assert_eq!(count(&a.memory_db, "%blue door%"), 1);
        // A's old memory is kept beside it, and A may start again.
        assert!(
            a.root
                .join(format!("{}.before-take-in-2", STORES[0]))
                .is_file()
        );
        assert!(crate::migrate::refusal(&a_home).is_none());
    }

    #[test]
    fn a_tampered_store_is_refused_and_nothing_placed() {
        let t = tempfile::tempdir().unwrap();
        let a_home = t.path().join("a");
        let a = crate::paths::Paths::new(&a_home);
        a.create().unwrap();
        seed_memory(&a.root, &["remember the blue door"]);
        let out = t.path().join("out");
        let w = hand_out(&a_home, "b", &out).unwrap();
        let c_home = t.path().join("c");
        let c = crate::paths::Paths::new(&c_home);
        c.create().unwrap();
        seed_memory(&c.root, &["c's own"]);
        project(&out, &c.root);
        std::fs::write(folder(&c.root).join(STORES[0]), b"not sqlite").unwrap();
        assert!(take_in(&c_home, &w).is_err());
        assert_eq!(count(&c.memory_db, "c's own"), 1);
        assert!(record(&c.root).is_none());
        assert!(!c.root.join(format!("{}.tmp-take-in", STORES[0])).exists());
    }

    /// One writer: a home that already handed its memory out is not the writer any more, so a
    /// second hand-out (a retry with another --to) would make two writers at one epoch.
    #[test]
    fn a_home_that_handed_out_cannot_hand_out_again() {
        let t = tempfile::tempdir().unwrap();
        let a_home = t.path().join("a");
        let a = crate::paths::Paths::new(&a_home);
        a.create().unwrap();
        seed_memory(&a.root, &["remember the blue door"]);
        hand_out(&a_home, "machine-b", &t.path().join("out1")).unwrap();
        let out2 = t.path().join("out2");
        assert!(hand_out(&a_home, "machine-c", &out2).is_err());
        assert!(read_writer(&out2).is_none());
    }

    /// The memory a take-in replaces is kept whole: rows a crashed host left only in its WAL
    /// stay with the `.before-take-in-EPOCH` copy, not deleted as the new file's side files.
    #[test]
    fn the_kept_memory_keeps_its_wal() {
        let t = tempfile::tempdir().unwrap();
        let a_home = t.path().join("a");
        let a = crate::paths::Paths::new(&a_home);
        a.create().unwrap();
        seed_memory(&a.root, &["remember the blue door"]);
        let out = t.path().join("out");
        let w = hand_out(&a_home, "c", &out).unwrap();

        let c_home = t.path().join("c");
        let c = crate::paths::Paths::new(&c_home);
        c.create().unwrap();
        // C's host crashed: its last rows are only in the WAL (a copy taken while it was open).
        let crashed = t.path().join("crashed");
        std::fs::create_dir_all(&crashed).unwrap();
        let conn = rusqlite::Connection::open(crashed.join(STORES[0])).unwrap();
        conn.execute_batch(
            "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; \
             CREATE TABLE log(id INTEGER PRIMARY KEY, text TEXT); \
             INSERT INTO log(text) VALUES ('only in the wal');",
        )
        .unwrap();
        std::fs::copy(crashed.join(STORES[0]), c.root.join(STORES[0])).unwrap();
        std::fs::copy(
            crashed.join(format!("{}-wal", STORES[0])),
            c.root.join(format!("{}-wal", STORES[0])),
        )
        .unwrap();
        drop(conn);

        project(&out, &c.root);
        take_in(&c_home, &w).unwrap();
        assert_eq!(count(&c.memory_db, "%blue door%"), 1);
        let kept = c
            .root
            .join(format!("{}.before-take-in-{}", STORES[0], w.epoch));
        assert_eq!(count(&kept, "only in the wal"), 1);
    }

    #[test]
    fn hand_out_without_memory_writes_no_writer() {
        let a = tempfile::tempdir().unwrap();
        let home = a.path().join("mux");
        crate::paths::Paths::new(&home).create().unwrap();
        let out = a.path().join("out");
        assert!(hand_out(&home, "b", &out).is_err());
        assert!(read_writer(&out).is_none());
        assert!(
            crate::migrate::refusal(&home).is_none(),
            "a failed hand-out keeps the source the writer"
        );
    }
}
