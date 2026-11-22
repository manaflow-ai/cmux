//! Where the Chief's memory lives: a projected folder (RFD 0007, `projection-v1`) when the
//! machine serves one, so the memory follows the Chief from one machine to another without a
//! copy first; else the plain files under `optchat/`, moved with `optchat-chief memory
//! export/import` (or a `move` checkpoint), as before.
//!
//! Leo, 2026-11-22: "chief in cloud. likely under our projection protocol or something, since it
//! has some semblance of memory or whatever, but they may be sized with their own vms."
//!
//! The memory is `memory.sqlite3` (log, tree, host state) and `memory-files.sqlite3` (notes,
//! rules, open loops). On a projected home both live in `optchat/memory/`, the mount point of a
//! projection named [`projection_name`]; everything else of the home stays where it was.
//!
//! The steps of a move from machine A to machine B:
//!
//! 1. **Hand out** on A (`optchat-chief memory hand-out --to MACHINE DIR`, host stopped): under
//!    the host lock, `VACUUM INTO` a consistent copy of each store into `DIR`, then `writer.json`
//!    last (epoch + 1, the one machine that may write it, each file's hash and row counts), then
//!    A's home is marked moved (`state/moved.json`), so A's host refuses to start. A crash before
//!    `writer.json` leaves no hand-out at all and A still the writer.
//! 2. **Project** `DIR` at B's `optchat/memory/` under the name [`projection_name`] (`cmux link
//!    project serve --socket S --at REMOTE --name NAME DIR`, the merged `projection.serve` dial;
//!    `hand-out --socket S --at REMOTE` starts it).
//! 3. **Take in** on B, by the host itself at its first start (or `memory take-in`): the folder
//!    must be a mount, `writer.json` must name this machine at an epoch above any this home took
//!    in before, and every file's hash and row counts must match. Each file is opened for writing
//!    and fsynced through the mount: that copies it whole into B's upper layer and puts it on B's
//!    disk, so B never needs A again. Then `optchat/memory-place.json` (machine-local) records the
//!    epoch, and every [`crate::paths::Paths`] of the home points into the folder.
//!
//! One writer at a time, and what enforces it:
//! - A projection never writes back to its source: B's writes land in B's upper layer, so no two
//!   machines ever write the same bytes; a second writer could only fork the memory, and these
//!   rules keep a fork from starting.
//! - The source stops being a writer before the hand-out exists: the host lock (flock) is held
//!   for the whole hand-out and `state/moved.json` is written before it is released, which the
//!   host already refuses to start on (`migrate::refusal`).
//! - Only the machine `writer.json` names takes the memory in, once per epoch: a third machine
//!   that mounts the same hand-out refuses it, and so does a machine that took this or a later
//!   epoch already.
//! - On one machine, the host lock (flock on `state/host.lock`) keeps a second host off the home.
//! - A projected home whose folder is not mounted refuses to start ([`Choice::Refuse`]) instead of
//!   opening an empty memory beside the real one.
//!
//! No loss when the machine dies mid-write: SQLite runs WAL with `synchronous=FULL` on the
//! mount, whose fsync is the upper file's `sync_all` and which has no writeback cache
//! (cmux-projection `mount.rs`), so a commit that returned is on the machine's disk, and the
//! upper layer survives a daemon restart (the projection attaches to it again by name, which is
//! why the name carries the epoch: a later hand-out never sits under an older upper layer). A
//! machine that is destroyed, not restarted, loses what it wrote since the hand-out: the
//! projection does not bring writes back yet, so the per-turn remote backup (`backup.rs`) and
//! `memory export` are what keep those.
//!
//! Going back: `optchat-chief memory place local` on a projected home copies the memory out of
//! the folder into `optchat/` (a `VACUUM INTO`, checked by row counts) and removes the record;
//! on the source, `optchat-chief move rollback` makes it the writer again.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

/// The daemon capability that mounts a projected folder (cmux-tui-core `projection.rs`).
pub const CAPABILITY: &str = "projection-v1";
/// The folder under `optchat/` a projected memory is mounted at.
pub const FOLDER: &str = "memory";
/// The hand-out's marker, written last into the folder.
pub const WRITER_FILE: &str = "writer.json";
/// This machine's record of a projected memory it took in (never carried by a move).
pub const RECORD_FILE: &str = "memory-place.json";
/// The stores that are the memory, by file name.
pub const STORES: [&str; 2] = ["memory.sqlite3", crate::memory_files::FILE];
/// The env switch projected folders share (`0`/`false` turns them off).
const ENV: &str = "CMUX_PROJECTED_FOLDERS";

/// The fallback steps when the memory cannot be projected.
pub const FALLBACK: &str = "move the memory with `optchat-chief memory export --text DIR` on the \
     old machine and `optchat-chief memory import DIR` on the new one (or `optchat-chief move`)";

/// `writer.json`: the hand-out of one epoch of the memory to one machine.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Writer {
    /// One more than the epoch the source held (0 for a memory never handed out).
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

/// `optchat/memory-place.json`: this machine holds the memory in the projected folder.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Record {
    pub place: String,
    pub epoch: u64,
    pub name: String,
    pub at: String,
}

/// What a start knows about the memory's place.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Inputs {
    /// The daemon advertised [`CAPABILITY`].
    pub capability: bool,
    /// Projected folders are not turned off ([`ENV`]).
    pub enabled: bool,
    /// This machine's record of a projected memory.
    pub record: Option<Record>,
    /// `optchat/memory/` is a mount.
    pub mounted: bool,
    /// The folder's `writer.json`, when readable.
    pub writer: Option<Writer>,
    /// This machine ([`machine_id`]).
    pub machine: String,
    /// `optchat/memory.sqlite3` exists (a memory kept as plain files).
    pub local_memory: bool,
}

/// Where this start keeps the memory.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Choice {
    /// In the projected folder, which this machine took in at the record's epoch.
    Projected,
    /// A hand-out to this machine is mounted and not taken in yet: take it in, then
    /// [`Choice::Projected`].
    TakeIn(Writer),
    /// The plain files under `optchat/`. `fallback` says why not projected and how the memory
    /// moves instead, when that is the reason (no capability, turned off); None for a memory
    /// kept local by choice (an existing memory is never moved without a hand-out).
    Local { fallback: Option<String> },
    /// Do not start: the memory is elsewhere or not this machine's to write.
    Refuse(String),
}

/// The pure rule: where the memory is, from what a start knows.
pub fn choose(inputs: &Inputs) -> Choice {
    let projectable = inputs.capability && inputs.enabled;
    if let Some(record) = &inputs.record {
        if !inputs.mounted {
            return Choice::Refuse(format!(
                "the memory is on a projected folder (epoch {}) that is not mounted at optchat/{FOLDER}: \
                 project it again (`cmux link project serve ... --name {}`), or {FALLBACK}",
                record.epoch, record.name
            ));
        }
        return match &inputs.writer {
            Some(w) if w.epoch > record.epoch && w.to == inputs.machine => {
                Choice::TakeIn(w.clone())
            }
            Some(w) if w.epoch == record.epoch && w.to == inputs.machine => Choice::Projected,
            Some(w) => Choice::Refuse(format!(
                "the projected memory is handed to {} at epoch {}, not to this machine at epoch {}: not writing it",
                w.to, w.epoch, record.epoch
            )),
            None => Choice::Refuse(format!(
                "the projected folder at optchat/{FOLDER} has no {WRITER_FILE}: not writing it"
            )),
        };
    }
    if inputs.mounted {
        return match &inputs.writer {
            Some(w) if w.to == inputs.machine && projectable => Choice::TakeIn(w.clone()),
            Some(w) if w.to == inputs.machine => Choice::Refuse(format!(
                "a projected memory is mounted here but this machine does not serve {CAPABILITY}: {FALLBACK}"
            )),
            Some(w) => Choice::Refuse(format!(
                "the projected memory is handed to {}, not to this machine ({}): not taking it",
                w.to, inputs.machine
            )),
            None => Choice::Refuse(format!(
                "optchat/{FOLDER} is a mount without {WRITER_FILE}: not a memory hand-out"
            )),
        };
    }
    let fallback = if !inputs.capability {
        Some(format!(
            "this machine does not serve {CAPABILITY}: {FALLBACK}"
        ))
    } else if !inputs.enabled {
        Some(format!("projected folders are off ({ENV}=0): {FALLBACK}"))
    } else {
        None
    };
    Choice::Local { fallback }
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

/// The record, when this machine took a projected memory in.
pub fn record(root: &Path) -> Option<Record> {
    let text = std::fs::read_to_string(root.join(RECORD_FILE)).ok()?;
    serde_json::from_str::<Record>(&text)
        .ok()
        .filter(|r| r.place == "projected")
}

/// The directory the memory's stores are in: the projected folder when recorded (or when it
/// holds the only memory, as after a `move` checkpoint carried it as plain files, without this
/// machine-local record), else `root`.
pub fn memory_dir(root: &Path) -> PathBuf {
    let only_in_folder = folder(root).join(STORES[0]).is_file() && !root.join(STORES[0]).exists();
    if only_in_folder || record(root).is_some() {
        folder(root)
    } else {
        root.to_owned()
    }
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

/// This machine's id: `/etc/machine-id`, else its host name.
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

/// The host start's step: takes a mounted hand-out in, or says why the host must not start.
/// Returns a line to log (the place, or why the memory stays plain files), or the refusal.
pub fn at_host_start(root: &Path, capability: bool) -> Result<String, String> {
    let inputs = inputs(root, capability);
    match choose(&inputs) {
        Choice::Projected => Ok(format!(
            "memory: projected folder {} (epoch {})",
            folder(root).display(),
            inputs.record.map_or(0, |r| r.epoch)
        )),
        Choice::TakeIn(w) => {
            let record = take_in(root, &w)?;
            Ok(format!(
                "memory: took in the projected memory from {} (epoch {}, projection {})",
                w.from, record.epoch, record.name
            ))
        }
        Choice::Local {
            fallback: Some(why),
        } => Ok(format!("memory: plain files; {why}")),
        Choice::Local { fallback: None } => Ok("memory: plain files".to_owned()),
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
    let paths = crate::paths::Paths::new(home);
    let src_dir = paths.memory_db.parent().unwrap_or(&paths.root).to_owned();
    crate::migrate::create_private_dir(out)?;
    if std::fs::read_dir(out)
        .map_err(|e| format!("{}: {e}", out.display()))?
        .next()
        .is_some()
    {
        return Err(format!("{} is not empty", out.display()));
    }
    let epoch = record(&paths.root).map_or(0, |r| r.epoch) + 1;
    let mut files = BTreeMap::new();
    for name in STORES {
        let from = src_dir.join(name);
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
        return Err(format!(
            "no memory at {}",
            src_dir.join(STORES[0]).display()
        ));
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
        &format!("projected:{to}"),
        &writer.files[STORES[0]].sha256,
    )?;
    Ok(writer)
}

/// Takes the mounted hand-out `writer` in on this machine: checks every store, copies each
/// into the upper layer (a write open) and fsyncs it, then writes the record.
pub fn take_in(root: &Path, writer: &Writer) -> Result<Record, String> {
    let dir = folder(root);
    for (name, want) in &writer.files {
        let path = dir.join(name);
        let got = store_of(&path)?;
        if got.sha256 != want.sha256 || got.rows != want.rows {
            return Err(format!(
                "{name} in the projected folder does not match its hand-out (sha256 {} rows {:?}, want {} {:?})",
                got.sha256, got.rows, want.sha256, want.rows
            ));
        }
        // A write open copies the whole file into this machine's upper layer; the fsync puts it
        // on this machine's disk, so the memory no longer needs the source.
        std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(&path)
            .and_then(|f| f.sync_all())
            .map_err(|e| format!("copying {name} onto this machine: {e}"))?;
    }
    let record = Record {
        place: "projected".into(),
        epoch: writer.epoch,
        name: projection_name(&writer.home_id, writer.epoch),
        at: crate::migrate::now_rfc3339(),
    };
    let text = serde_json::to_string_pretty(&record).map_err(|e| e.to_string())?;
    write_atomic(&root.join(RECORD_FILE), text.as_bytes())?;
    Ok(record)
}

/// Brings a projected memory back to plain files under `root` (host stopped): each store is
/// copied out with `VACUUM INTO`, checked by row counts, and only then the record goes. An
/// existing plain memory is kept beside it (`.before-local-<epoch>`), never overwritten.
pub fn place_local(root: &Path) -> Result<String, String> {
    let Some(rec) = record(root) else {
        return Ok("the memory is already kept as plain files".into());
    };
    let dir = folder(root);
    for name in STORES {
        let from = dir.join(name);
        if !from.exists() {
            continue;
        }
        let to = root.join(name);
        let tmp = root.join(format!("{name}.tmp-local"));
        let _ = std::fs::remove_file(&tmp);
        crate::migrate::vacuum_into(&from, &tmp)?;
        let (want, got) = (
            crate::migrate::table_counts(&from)?,
            crate::migrate::table_counts(&tmp)?,
        );
        if want != got {
            let _ = std::fs::remove_file(&tmp);
            return Err(format!("{name}: copied rows {got:?} differ from {want:?}"));
        }
        if to.exists() {
            let kept = root.join(format!("{name}.before-local-{}", rec.epoch));
            std::fs::rename(&to, &kept).map_err(|e| format!("keeping {}: {e}", to.display()))?;
        }
        std::fs::rename(&tmp, &to).map_err(|e| format!("placing {}: {e}", to.display()))?;
    }
    sync_dir(root);
    std::fs::remove_file(root.join(RECORD_FILE))
        .map_err(|e| format!("removing the record: {e}"))?;
    sync_dir(root);
    Ok(format!(
        "the memory (epoch {}) is plain files under {} again; `cmux link project stop --at {}` ends its projection",
        rec.epoch,
        root.display(),
        dir.display()
    ))
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
        Choice::Projected => format!(
            "projected folder {} (epoch {})",
            folder(root).display(),
            inputs.record.as_ref().map_or(0, |r| r.epoch)
        ),
        Choice::TakeIn(w) => format!(
            "a hand-out (epoch {}) is mounted, not taken in yet",
            w.epoch
        ),
        Choice::Local {
            fallback: Some(why),
        } => format!("plain files under {}; {why}", root.display()),
        Choice::Local { fallback: None } => format!(
            "plain files under {} (an existing memory moves to a projected folder only by `memory hand-out`)",
            root.display()
        ),
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

    fn record(epoch: u64) -> Record {
        Record {
            place: "projected".into(),
            epoch,
            name: projection_name("0123abcd", epoch),
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
    fn taken_in_epoch_is_projected() {
        let choice = choose(&Inputs {
            record: Some(record(2)),
            mounted: true,
            writer: Some(writer(2, "b")),
            ..base()
        });
        assert_eq!(choice, Choice::Projected);
    }

    #[test]
    fn a_later_epoch_to_this_machine_is_taken_in_an_older_one_refused() {
        let later = choose(&Inputs {
            record: Some(record(2)),
            mounted: true,
            writer: Some(writer(3, "b")),
            ..base()
        });
        assert!(matches!(later, Choice::TakeIn(ref w) if w.epoch == 3));
        let older = choose(&Inputs {
            record: Some(record(2)),
            mounted: true,
            writer: Some(writer(1, "b")),
            ..base()
        });
        assert!(matches!(older, Choice::Refuse(_)), "{older:?}");
    }

    #[test]
    fn recorded_but_unmounted_refuses_instead_of_an_empty_memory() {
        let choice = choose(&Inputs {
            record: Some(record(1)),
            mounted: false,
            local_memory: false,
            ..base()
        });
        assert!(
            matches!(choice, Choice::Refuse(ref w) if w.contains("not mounted") && w.contains("memory export"))
        );
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

    fn seed_memory(dir: &Path) {
        std::fs::create_dir_all(dir).unwrap();
        let conn = rusqlite::Connection::open(dir.join(STORES[0])).unwrap();
        conn.execute_batch(
            "PRAGMA journal_mode=WAL; CREATE TABLE log(id INTEGER PRIMARY KEY, text TEXT);
             INSERT INTO log(text) VALUES ('remember the blue door'), ('second');",
        )
        .unwrap();
    }

    /// The whole path on one disk: a plain folder stands in for the mount (the FUSE mount and
    /// its copy-up are cmux-projection's, tested there).
    #[test]
    fn hand_out_take_in_and_back_round_trip() {
        let a = tempfile::tempdir().unwrap();
        let b = tempfile::tempdir().unwrap();
        let a_home = a.path().join("mux");
        let a_paths = crate::paths::Paths::new(&a_home);
        a_paths.create().unwrap();
        seed_memory(&a_paths.root);
        let out = a.path().join("out");
        let w = hand_out(&a_home, "machine-b", &out).unwrap();
        assert_eq!(w.epoch, 1);
        assert_eq!(w.files[STORES[0]].rows["log"], 2);
        // The source refuses to start now: one writer.
        assert!(crate::migrate::refusal(&a_home).is_some());
        // A second hand-out into the same folder is refused.
        assert!(hand_out(&a_home, "machine-b", &out).is_err());

        // Machine B: the projected folder is mounted at optchat/memory (a copy here).
        let b_home = b.path().join("mux");
        let b_paths = crate::paths::Paths::new(&b_home);
        b_paths.create().unwrap();
        let dir = folder(&b_paths.root);
        std::fs::create_dir_all(&dir).unwrap();
        for entry in std::fs::read_dir(&out).unwrap() {
            let entry = entry.unwrap();
            std::fs::copy(entry.path(), dir.join(entry.file_name())).unwrap();
        }
        let inputs = Inputs {
            mounted: true,
            writer: read_writer(&dir),
            machine: "machine-b".into(),
            capability: true,
            enabled: true,
            ..Inputs::default()
        };
        let Choice::TakeIn(w) = choose(&inputs) else {
            panic!()
        };
        take_in(&b_paths.root, &w).unwrap();
        // Every Paths of the home now points into the projected folder.
        let after = crate::paths::Paths::new(&b_home);
        assert_eq!(after.memory_db, dir.join(STORES[0]));
        let n: i64 = rusqlite::Connection::open(&after.memory_db)
            .unwrap()
            .query_row(
                "SELECT count(*) FROM log WHERE text LIKE '%blue door%'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(n, 1);
        // The same hand-out is not taken twice.
        let again = Inputs {
            record: record_of(&b_paths.root),
            ..inputs.clone()
        };
        assert_eq!(choose(&again), Choice::Projected);

        // A tampered store is refused.
        let c = tempfile::tempdir().unwrap();
        let c_root = c.path().join("optchat");
        std::fs::create_dir_all(folder(&c_root)).unwrap();
        std::fs::write(folder(&c_root).join(STORES[0]), b"not sqlite").unwrap();
        assert!(take_in(&c_root, &w).is_err());

        // Going back to plain files keeps every row.
        place_local(&b_paths.root).unwrap();
        let back = crate::paths::Paths::new(&b_home);
        assert_eq!(back.memory_db, b_paths.root.join(STORES[0]));
        assert_eq!(
            crate::migrate::table_counts(&back.memory_db).unwrap()["log"],
            2
        );
    }

    fn record_of(root: &Path) -> Option<Record> {
        super::record(root)
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
