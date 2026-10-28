//! `__bg-run`: one background task an agent started through the daemon (`hub/bg_tasks.rs`,
//! docs/hibernation.md). Leo, 2026-10-27: "also when it comes to hibernation...can't you
//! hibernate the agent but not hibernate the bg tasks?" A harness's own background shells end
//! with the harness (Claude Code's exit cleanup, Codex's `terminate_all_processes`), so a task
//! that must outlive a hibernated agent runs here instead: the daemon starts this runner in a
//! session of its own, never under the harness, and it outlives the harness and the daemon.
//!
//! The runner reads its [`Spec`] as one JSON line on stdin. Before the task starts it holds
//! `<id>.lock` (the lock, not a pid, says it runs), opens its stop FIFO `<id>.ctl` and creates the
//! task's first output segment. Then it starts `bash -c COMMAND` (`/bin/sh` where there is no
//! `/bin/bash`), the shell the agent's Bash tool means, as the leader of a new session
//! (setsid), writes `<id>.json` and answers one line on stdout; if either fails it stops the task.
//!
//! Output: segment files `<id>.out.<start>`, named by where they start in the task's whole output,
//! so the files alone say what is kept (a crash never leaves them disagreeing with a record). At
//! `segment` bytes a new file starts and the one before the previous is deleted: at most two are
//! kept, the newest 8 MiB by default. A reader opens the files first and reads its descriptors.
//!
//! Stop: one byte written to `<id>.ctl`. A writer's open fails (ENXIO) unless this runner holds
//! the FIFO open, so a stop never reaches anything but this runner; nothing signals its pid. Before
//! the task starts, SIGTERM or SIGINT ends the runner; after, it stops the task like a stop byte
//! does: SIGTERM to the task's own group, then SIGKILL to the group after [`GRACE`]. Only the
//! runner signals that group, and only before it reaps the leader, so the group id is still the
//! task's. SIGHUP is ignored. The runner learns the leader's exit with `waitid(WNOWAIT)` and reaps
//! it only once the pipe ends, so output a child it left writes later is kept and a stop still
//! reaches that child. Once a stop began, the reap also waits for its SIGKILL: a member that
//! ignores SIGTERM and holds no pipe (its output sent elsewhere) is killed too, never left once
//! the pipe ends. A stop whose SIGKILL leaves the pipe open (a process that left the group holds
//! it) ends the wait after one more grace. Then the runner writes the exit and exits.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

pub const RUN_ARG: &str = "__bg-run";
/// The default segment: two of them, 8 MiB, are the most a task keeps.
pub const SEGMENT: u64 = 4 << 20;
/// From SIGTERM to SIGKILL on a stop.
pub const GRACE: std::time::Duration = std::time::Duration::from_secs(5);

/// What the daemon hands the runner.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Spec {
    pub dir: PathBuf,
    pub id: String,
    pub session_id: String,
    pub command: String,
    pub cwd: PathBuf,
    /// The task's whole environment (the runner's own is not passed on).
    #[serde(default)]
    pub env: BTreeMap<String, String>,
    pub segment: u64,
}

/// `<id>.json`, written whole (to a temporary file, then renamed) each time it changes.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Record {
    pub id: String,
    pub session_id: String,
    pub command: String,
    pub cwd: String,
    pub pid: u32,
    pub started_at: u64,
    pub ended_at: Option<u64>,
    pub exit_code: Option<i32>,
    pub signal: Option<i32>,
    /// A stop asked for its end.
    #[serde(default)]
    pub stopped: bool,
    /// Why its output stopped being kept (a full disk); the task ran on.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output_error: Option<String>,
}

fn file(dir: &Path, id: &str, ext: &str) -> PathBuf {
    dir.join(format!("{id}.{ext}"))
}
pub fn lock_path(dir: &Path, id: &str) -> PathBuf {
    file(dir, id, "lock")
}
pub fn ctl_path(dir: &Path, id: &str) -> PathBuf {
    file(dir, id, "ctl")
}
fn segment_path(dir: &Path, id: &str, start: u64) -> PathBuf {
    file(dir, id, &format!("out.{start}"))
}

/// One writer at a time: the runner writes its record from one lock (`main`).
pub fn write_record(dir: &Path, record: &Record) -> std::io::Result<()> {
    let tmp = file(dir, &record.id, "json.tmp");
    std::fs::write(&tmp, serde_json::to_vec(record)?)?;
    std::fs::rename(&tmp, file(dir, &record.id, "json"))
}

pub fn read_record(dir: &Path, id: &str) -> Option<Record> {
    serde_json::from_slice(&std::fs::read(file(dir, id, "json")).ok()?).ok()
}

/// The task's segments, oldest first, by the start in their names.
fn segments(dir: &Path, id: &str) -> Vec<u64> {
    let prefix = format!("{id}.out.");
    let mut starts: Vec<u64> = std::fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| e.file_name().to_str()?.strip_prefix(&prefix)?.parse().ok())
        .collect();
    starts.sort_unstable();
    starts
}

/// The bounded output; [`Spool::write`] starts a new segment at `segment` bytes.
pub struct Spool {
    dir: PathBuf,
    id: String,
    segment: u64,
    file: std::fs::File,
    prev: Option<u64>,
    start: u64,
    len: u64,
}

impl Spool {
    pub fn create(dir: &Path, id: &str, segment: u64) -> std::io::Result<Self> {
        let file = std::fs::File::create(segment_path(dir, id, 0))?;
        let (dir, id) = (dir.to_owned(), id.to_owned());
        Ok(Self { dir, id, segment: segment.max(1), file, prev: None, start: 0, len: 0 })
    }

    pub fn write(&mut self, mut data: &[u8]) -> std::io::Result<()> {
        use std::io::Write;
        while !data.is_empty() {
            if self.len >= self.segment {
                let start = self.start + self.len;
                self.file = std::fs::File::create(segment_path(&self.dir, &self.id, start))?;
                if let Some(old) = self.prev.replace(self.start) {
                    let _ = std::fs::remove_file(segment_path(&self.dir, &self.id, old));
                }
                (self.start, self.len) = (start, 0);
            }
            let n = data.len().min((self.segment - self.len) as usize);
            self.file.write_all(&data[..n])?;
            self.len += n as u64;
            data = &data[n..];
        }
        Ok(())
    }
}

/// What [`read_output`] read.
#[derive(Debug, Default)]
pub struct Output {
    pub data: Vec<u8>,
    /// Where `data` starts in the whole output.
    pub start: u64,
    /// The whole output's length.
    pub total: u64,
    /// The oldest byte still kept.
    pub kept_from: u64,
}

/// Up to `max` bytes of a task's output from `from` (`None`: its last `max`). A start before the
/// oldest kept byte reads from it. A spool that rotated under every try is an error, never an
/// empty read (a reader would take it for no output and start again from 0).
pub fn read_output(dir: &Path, id: &str, from: Option<u64>, max: u64) -> std::io::Result<Output> {
    use std::io::{Read, Seek, SeekFrom};
    // The newest two segments, opened before anything is measured: a rotation meanwhile deletes
    // a name but not an open file, and every segment but the newest no longer grows.
    let mut open = None;
    for _ in 0..3 {
        let starts = segments(dir, id);
        let opened: std::io::Result<Vec<_>> = starts[starts.len().saturating_sub(2)..]
            .iter()
            .map(|&s| std::fs::File::open(segment_path(dir, id, s)).map(|f| (s, f)))
            .collect();
        match opened {
            Ok(files) => {
                open = Some(files);
                break;
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
            Err(e) => return Err(e),
        }
    }
    let mut open = open.ok_or_else(|| {
        std::io::Error::new(
            std::io::ErrorKind::Interrupted,
            "the task's output rotated while it was read; read again",
        )
    })?;
    let Some((last, last_file)) = open.last() else { return Ok(Output::default()) };
    let total = last + last_file.metadata()?.len();
    let kept_from = open[0].0;
    let start = from.map_or(total.saturating_sub(max), |f| f.min(total)).max(kept_from);
    let end = total.min(start.saturating_add(max));
    let starts: Vec<u64> = open.iter().map(|(s, _)| *s).collect();
    let mut data = Vec::new();
    for (i, (base, f)) in open.iter_mut().enumerate() {
        let seg_end = starts.get(i + 1).copied().unwrap_or(end).min(end);
        let at = start + data.len() as u64;
        if at >= seg_end || at < *base {
            continue;
        }
        f.seek(SeekFrom::Start(at - *base))?;
        f.take(seg_end - at).read_to_end(&mut data)?;
    }
    Ok(Output { data, start, total, kept_from })
}

/// Asks the task's runner to stop it; false when no runner holds its FIFO (the task ended).
#[cfg(unix)]
pub fn request_stop(dir: &Path, id: &str) -> bool {
    use std::io::Write;
    use std::os::unix::fs::{FileTypeExt, OpenOptionsExt};
    let path = ctl_path(dir, id);
    if !std::fs::symlink_metadata(&path).is_ok_and(|m| m.file_type().is_fifo()) {
        return false;
    }
    let opened = std::fs::OpenOptions::new()
        .write(true)
        .custom_flags(libc::O_NONBLOCK | libc::O_NOFOLLOW)
        .open(&path);
    opened.and_then(|mut f| f.write_all(b"s")).is_ok()
}
#[cfg(not(unix))]
pub fn request_stop(_dir: &Path, _id: &str) -> bool {
    false
}

/// The runner process: never returns while the task runs.
#[cfg(unix)]
pub fn main() -> anyhow::Result<()> {
    use std::io::{BufRead, Read, Write};
    use std::os::fd::AsRawFd;
    use std::os::unix::process::{CommandExt, ExitStatusExt};
    use std::sync::{Arc, Mutex};
    let mut line = String::new();
    std::io::stdin().lock().read_line(&mut line)?;
    let spec: Spec = serde_json::from_str(&line)?;
    // SAFETY: plain signal-mask calls before any thread starts; the signal thread takes them.
    let mut set: libc::sigset_t = unsafe { std::mem::zeroed() };
    unsafe {
        libc::sigemptyset(&mut set);
        for s in [libc::SIGTERM, libc::SIGINT, libc::SIGHUP] {
            libc::sigaddset(&mut set, s);
        }
        libc::pthread_sigmask(libc::SIG_BLOCK, &set, std::ptr::null_mut());
    }
    // A closed pipe is an error to see, never a death (the task gets SIGPIPE back, `setup`).
    // SAFETY: setting a signal disposition before any thread starts.
    unsafe { libc::signal(libc::SIGPIPE, libc::SIG_IGN) };
    let (dir, id) = (spec.dir.clone(), spec.id.clone());
    /// The task's pid once it runs, whether it was reaped (from then on its group id may be
    /// another's), and its record: one lock, so a stop never interleaves with the start, the
    /// reap or a record write.
    struct Task {
        pid: Option<u32>,
        reaped: bool,
        stopping: bool,
        record: Record,
    }
    let task = Arc::new(Mutex::new(Task {
        pid: None,
        reaped: false,
        stopping: false,
        record: Record::default(),
    }));
    // What a stop that SIGKILLed the group sends when the pipe still has not ended.
    let give_up: Arc<Mutex<Option<std::sync::mpsc::Sender<()>>>> = Arc::new(Mutex::new(None));
    // Set once a stop sent its SIGKILL: the reap waits for it, so the group id stays the task's
    // until then.
    let killed = Arc::new((Mutex::new(false), std::sync::Condvar::new()));
    let stop = {
        let (task, dir, give_up, killed) =
            (task.clone(), dir.clone(), give_up.clone(), killed.clone());
        move || {
            let mut held = task.lock().unwrap_or_else(|e| e.into_inner());
            let Some(pid) = held.pid else { std::process::exit(1) };
            if std::mem::replace(&mut held.stopping, true) {
                return;
            }
            held.record.stopped = true;
            let _ = write_record(&dir, &held.record);
            drop(held);
            let (task, give_up, killed) = (task.clone(), give_up.clone(), killed.clone());
            std::thread::spawn(move || {
                for signal in [libc::SIGTERM, libc::SIGKILL] {
                    let held = task.lock().unwrap_or_else(|e| e.into_inner());
                    if held.reaped {
                        return;
                    }
                    // SAFETY: the leader is unreaped (checked under the lock, and the reap waits
                    // for the SIGKILL below), so the group is the task's.
                    unsafe { libc::killpg(pid as i32, signal) };
                    drop(held);
                    if signal == libc::SIGKILL {
                        *killed.0.lock().unwrap_or_else(|e| e.into_inner()) = true;
                        killed.1.notify_all();
                    }
                    std::thread::sleep(GRACE);
                }
                // Killed and still not done: a process outside the group holds the pipe.
                if let Some(done) = give_up.lock().unwrap_or_else(|e| e.into_inner()).as_ref() {
                    let _ = done.send(());
                }
            });
        }
    };
    {
        let stop = stop.clone();
        std::thread::spawn(move || {
            loop {
                let mut sig = 0;
                // SAFETY: waits for a signal of the set every thread blocks.
                if unsafe { libc::sigwait(&set, &mut sig) } == 0 && sig != libc::SIGHUP {
                    stop();
                }
            }
        });
    }
    let lock = std::fs::File::create(lock_path(&dir, &id))?;
    // SAFETY: flock on a descriptor this process owns (close-on-exec: the task never holds it).
    if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        anyhow::bail!("task {id} already runs");
    }
    let ctl = ctl_path(&dir, &id);
    // A start that fails leaves nothing behind but the lock it held.
    let undo = || {
        let _ = std::fs::remove_file(&ctl);
        let _ = std::fs::remove_file(segment_path(&dir, &id, 0));
    };
    let setup = || -> anyhow::Result<_> {
        let _ = std::fs::remove_file(&ctl);
        let c = std::ffi::CString::new(ctl.as_os_str().as_encoded_bytes())?;
        // SAFETY: mkfifo on a path this function owns.
        if unsafe { libc::mkfifo(c.as_ptr(), 0o600) } != 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        // Read and write: the FIFO never reads as closed, and a stop's open finds a reader.
        let control = std::fs::OpenOptions::new().read(true).write(true).open(&ctl)?;
        let spool = Spool::create(&dir, &id, spec.segment)?;
        let (reader, writer) = std::io::pipe()?;
        let shell = ["/bin/bash", "/bin/sh"].into_iter().find(|s| Path::new(s).exists());
        let mut cmd = std::process::Command::new(shell.unwrap_or("/bin/sh"));
        // Exactly the env the daemon built (the agent's), never this runner's own on top of it.
        cmd.arg("-c").arg(&spec.command).current_dir(&spec.cwd).env_clear().envs(&spec.env);
        cmd.stdin(std::process::Stdio::null()).stdout(writer.try_clone()?).stderr(writer);
        // SAFETY: setsid, signal and sigprocmask are async-signal-safe. The task leads its own
        // session and group, with SIGPIPE back to its default and no signal blocked.
        unsafe {
            cmd.pre_exec(|| {
                if libc::setsid() < 0 {
                    return Err(std::io::Error::last_os_error());
                }
                libc::signal(libc::SIGPIPE, libc::SIG_DFL);
                let empty: libc::sigset_t = std::mem::zeroed();
                libc::sigprocmask(libc::SIG_SETMASK, &empty, std::ptr::null_mut());
                Ok(())
            });
        }
        let mut held = task.lock().unwrap_or_else(|e| e.into_inner());
        let child = cmd.spawn()?;
        let pid = child.id();
        held.pid = Some(pid);
        held.record = Record {
            id: id.clone(),
            session_id: spec.session_id.clone(),
            command: spec.command.clone(),
            cwd: spec.cwd.to_string_lossy().into_owned(),
            pid,
            started_at: crate::store::now_ms(),
            ..Record::default()
        };
        // A closed answer pipe is an error here, never a SIGPIPE (ignored since the start).
        let answered = write_record(&dir, &held.record).and_then(|()| {
            let mut out = std::io::stdout().lock();
            writeln!(out, "{}", serde_json::json!({"pid": pid}))?;
            out.flush()
        });
        Ok((control, spool, reader, child, answered))
    };
    let (mut control, mut spool, mut reader, mut child, answered) = match setup() {
        Ok(started) => started,
        Err(e) => {
            undo();
            return Err(e);
        }
    };
    // Unrecorded or unanswered, the task is stopped: nothing could find it.
    if answered.is_err() {
        stop();
    }
    std::thread::spawn(move || {
        let mut byte = [0u8; 1];
        while control.read(&mut byte).is_ok_and(|n| n > 0) {
            stop();
        }
    });
    let (done_tx, done_rx) = std::sync::mpsc::channel::<()>();
    *give_up.lock().unwrap_or_else(|e| e.into_inner()) = Some(done_tx.clone());
    {
        let (task, dir) = (task.clone(), dir.clone());
        std::thread::spawn(move || {
            let mut buf = vec![0u8; 64 << 10];
            let mut failed = false;
            while let Ok(n) = reader.read(&mut buf) {
                if n == 0 {
                    break;
                }
                // A spool that fails is said in the record; the pipe is still read, so the
                // task never blocks on it.
                if !failed && let Err(e) = spool.write(&buf[..n]) {
                    failed = true;
                    let mut held = task.lock().unwrap_or_else(|e| e.into_inner());
                    held.record.output_error = Some(e.to_string());
                    let _ = write_record(&dir, &held.record);
                }
            }
            let _ = done_tx.send(());
        });
    }
    let pid = child.id();
    // The leader's exit, learned without reaping it: until the reap its pid keeps the group id
    // the task's, so a stop still reaches what it left behind.
    // SAFETY: waitid into a zeroed siginfo this function owns; WNOWAIT leaves the leader unreaped.
    let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
    while unsafe { libc::waitid(libc::P_PID, pid, &mut info, libc::WEXITED | libc::WNOWAIT) } != 0
        && std::io::Error::last_os_error().raw_os_error() == Some(libc::EINTR)
    {}
    // Then every byte: the pipe's EOF, when the last process holding it (a child the leader left)
    // is gone, or a stop's end (its SIGKILL and grace) when one left the group and holds it.
    let _ = done_rx.recv();
    {
        let mut held = task.lock().unwrap_or_else(|e| e.into_inner());
        // A stop that began finishes first: its SIGKILL reaches what ignored SIGTERM.
        if held.stopping {
            drop(held);
            let mut sent = killed.0.lock().unwrap_or_else(|e| e.into_inner());
            while !*sent {
                sent = killed.1.wait(sent).unwrap_or_else(|e| e.into_inner());
            }
            drop(sent);
            held = task.lock().unwrap_or_else(|e| e.into_inner());
        }
        held.reaped = true;
        let status = child.wait().ok();
        held.record.ended_at = Some(crate::store::now_ms());
        held.record.exit_code = status.and_then(|s| s.code());
        held.record.signal = status.and_then(|s| s.signal());
        let _ = write_record(&dir, &held.record);
    }
    let _ = std::fs::remove_file(&ctl);
    drop(lock);
    std::process::exit(0)
}

#[cfg(not(unix))]
pub fn main() -> anyhow::Result<()> {
    Err(crate::platform::unsupported("background tasks"))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Rotation keeps the newest two segments, named by their start, and a read by whole-output
    /// offset crosses them; one before the oldest kept byte starts at it.
    #[test]
    fn the_spool_keeps_two_segments_and_reads_across_them() {
        let dir = cmux_unix_socket::short_test_dir("bg-spool");
        let mut spool = Spool::create(dir.path(), "t", 10).unwrap();
        let data: Vec<u8> = (0..35u8).map(|i| b'a' + i % 26).collect();
        for chunk in data.chunks(4) {
            spool.write(chunk).unwrap();
        }
        assert_eq!(segments(dir.path(), "t"), [20, 30]);
        let tail = read_output(dir.path(), "t", None, 8).unwrap();
        assert_eq!((tail.start, tail.total, tail.kept_from), (27, 35, 20));
        assert_eq!(tail.data, data[27..]);
        let across = read_output(dir.path(), "t", Some(0), 12).unwrap();
        assert_eq!((across.start, across.data.as_slice()), (20, &data[20..32]));
    }

    /// A segment that is listed but gone at every open (here a dangling link, as a rotation
    /// between the listing and the open leaves it) is an error, not an empty output; a spool
    /// with no segment at all is empty.
    #[cfg(unix)]
    #[test]
    fn a_read_that_loses_every_race_with_rotation_is_an_error() {
        let dir = cmux_unix_socket::short_test_dir("bg-spool-race");
        let none = read_output(dir.path(), "t", None, 8).unwrap();
        assert_eq!((none.data.len(), none.total), (0, 0));
        let mut spool = Spool::create(dir.path(), "t", 10).unwrap();
        spool.write(b"0123456789abc").unwrap();
        let gone = segment_path(dir.path(), "t", 0);
        std::fs::remove_file(&gone).unwrap();
        std::os::unix::fs::symlink(dir.path().join("nowhere"), &gone).unwrap();
        let err = read_output(dir.path(), "t", None, 8).unwrap_err();
        assert_eq!(err.kind(), std::io::ErrorKind::Interrupted, "{err}");
    }
}
