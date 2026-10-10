//! The daemon start on Windows: what `setsid`, `pipe` and inherited
//! descriptors do on Unix.
//!
//! A client starts `<exe> [prefix] daemon run --ready-fd <handle>` with
//! CreateProcessW. The child inherits exactly four handles, named in a
//! PROC_THREAD_ATTRIBUTE_HANDLE_LIST: the readiness pipe's write end, NUL as
//! stdin and the daemon log as stdout and stderr. Nothing else this process
//! holds (sockets, other pipes, the lock file) reaches it. The daemon runs in
//! its own process group with a hidden console (CREATE_NO_WINDOW): its
//! console children (agent harnesses, shells) then open no windows, which
//! DETACHED_PROCESS would not give. It breaks away from this process's job
//! when the job allows it, so it outlives the terminal or ssh session that
//! started it.
//!
//! `--ready-fd` and `--person-key-fd` carry inherited handle values on
//! Windows (0, 1 and 2 name the standard handles, as the descriptors do on
//! Unix).

use anyhow::{Context, Result, anyhow};
use serde_json::Value;
use std::ffi::{OsStr, OsString};
use std::fs::File;
use std::io::{Read, Write};
use std::os::windows::ffi::OsStrExt;
use std::os::windows::io::{AsRawHandle, FromRawHandle};
use std::path::Path;
use std::ptr::{null, null_mut};
use windows_sys::Win32::Foundation::{
    CloseHandle, ERROR_ACCESS_DENIED, HANDLE, HANDLE_FLAG_INHERIT, SetHandleInformation,
};
use windows_sys::Win32::System::Pipes::CreatePipe;
use windows_sys::Win32::System::Threading::{
    CREATE_BREAKAWAY_FROM_JOB, CREATE_NEW_PROCESS_GROUP, CREATE_NO_WINDOW,
    CREATE_UNICODE_ENVIRONMENT, CreateProcessW, DeleteProcThreadAttributeList,
    EXTENDED_STARTUPINFO_PRESENT, InitializeProcThreadAttributeList, LPPROC_THREAD_ATTRIBUTE_LIST,
    PROC_THREAD_ATTRIBUTE_HANDLE_LIST, PROCESS_INFORMATION, STARTF_USESTDHANDLES, STARTUPINFOEXW,
    UpdateProcThreadAttribute,
};

/// The handle a `--ready-fd` / `--person-key-fd` value names: a standard
/// handle for 0-2, else the inherited value (sign-extended, as
/// `LongToHandle` does; handle values fit in 32 bits).
fn named_handle(fd: i32) -> HANDLE {
    match fd {
        0 => std::io::stdin().as_raw_handle(),
        1 => std::io::stdout().as_raw_handle(),
        2 => std::io::stderr().as_raw_handle(),
        _ => fd as isize as HANDLE,
    }
}

/// Keeps an inherited readiness handle out of every process the daemon
/// starts before it writes the line (what FD_CLOEXEC does on Unix).
pub(super) fn keep_from_children(fd: i32) {
    if fd > 2 {
        // SAFETY: a handle value; an invalid one only fails.
        unsafe { SetHandleInformation(named_handle(fd), HANDLE_FLAG_INHERIT, 0) };
    }
}

/// Reads the person key (one line, at most 128 bytes) from an inherited
/// handle and closes it. The key is never logged.
pub(super) fn read_person_key(fd: i32) -> Option<String> {
    if fd <= 2 {
        tracing::warn!("--person-key-fd {fd}: not a standard handle");
        return None;
    }
    // SAFETY: the launcher passed this handle for us to read and close;
    // `File` owns and closes it here.
    let f = unsafe { File::from_raw_handle(named_handle(fd)) };
    let mut buf = Vec::with_capacity(80);
    if let Err(e) = f.take(128).read_to_end(&mut buf) {
        tracing::warn!("--person-key-fd {fd}: {e}");
        return None;
    }
    let key = String::from_utf8(buf).ok()?.trim().to_owned();
    if crate::hub::person::valid_key(&key) {
        Some(key)
    } else {
        tracing::warn!("--person-key-fd {fd}: not a person key");
        None
    }
}

/// Writes the readiness line to an inherited handle and closes it (never a
/// standard handle).
pub(super) fn write_ready(fd: i32, ready: &Value) {
    if fd < 0 {
        return;
    }
    let mut line = ready.to_string();
    line.push('\n');
    // SAFETY: the launcher passed this handle for us to write (and close).
    let mut f = std::mem::ManuallyDrop::new(unsafe { File::from_raw_handle(named_handle(fd)) });
    if let Err(e) = f.write_all(line.as_bytes()) {
        tracing::warn!("--ready-fd {fd}: {e}");
    }
    if fd > 2 {
        // SAFETY: taken once; closes the handle.
        drop(unsafe { std::mem::ManuallyDrop::take(&mut f) });
    }
}

fn set_inherit(handle: HANDLE, inherit: bool) -> std::io::Result<()> {
    // SAFETY: a handle this process owns.
    if unsafe { SetHandleInformation(handle, HANDLE_FLAG_INHERIT, u32::from(inherit)) } == 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(())
}

/// An anonymous pipe, neither end inheritable: (read, write).
fn pipe() -> std::io::Result<(File, File)> {
    let (mut read, mut write): (HANDLE, HANDLE) = (null_mut(), null_mut());
    // SAFETY: out-pointers valid; no security attributes (not inheritable).
    if unsafe { CreatePipe(&mut read, &mut write, null(), 0) } == 0 {
        return Err(std::io::Error::last_os_error());
    }
    // SAFETY: both handles were just created and are owned here.
    Ok(unsafe { (File::from_raw_handle(read), File::from_raw_handle(write)) })
}

/// Appends `arg` to a command line with the quoting CommandLineToArgvW and
/// the C runtime undo.
fn push_arg(line: &mut Vec<u16>, arg: &OsStr) {
    const QUOTE: u16 = b'"' as u16;
    const BACKSLASH: u16 = b'\\' as u16;
    if !line.is_empty() {
        line.push(u16::from(b' '));
    }
    let wide: Vec<u16> = arg.encode_wide().collect();
    let plain = !wide.is_empty()
        && !wide.iter().any(|&c| c == u16::from(b' ') || c == u16::from(b'\t') || c == QUOTE);
    if plain {
        line.extend(wide);
        return;
    }
    line.push(QUOTE);
    let mut backslashes = 0usize;
    for c in wide {
        if c == BACKSLASH {
            backslashes += 1;
        } else {
            if c == QUOTE {
                // Each backslash before a quote doubles, and the quote is escaped.
                line.extend(std::iter::repeat_n(BACKSLASH, backslashes + 1));
            }
            backslashes = 0;
        }
        line.push(c);
    }
    // Backslashes before the closing quote double.
    line.extend(std::iter::repeat_n(BACKSLASH, backslashes));
    line.push(QUOTE);
}

/// This process's environment for the daemon: `ACPMUX_HOME` set to `home`
/// (a host override its own environment would not reproduce), without the
/// nested Claude keys `scrub_nested_claude_env` removes. Sorted, as
/// CreateProcessW expects (names compare without case).
fn environment_block(home: &Path) -> Vec<u16> {
    let drop: Vec<String> = crate::config::nested_claude_keys()
        .iter()
        .map(|k| k.to_string_lossy().to_uppercase())
        .collect();
    let mut vars: Vec<(OsString, OsString)> = std::env::vars_os()
        .filter(|(k, _)| {
            let upper = k.to_string_lossy().to_uppercase();
            upper != "ACPMUX_HOME" && !drop.contains(&upper)
        })
        .collect();
    vars.push(("ACPMUX_HOME".into(), home.as_os_str().to_owned()));
    vars.sort_by_key(|(k, _)| k.to_string_lossy().to_uppercase());
    let mut block = Vec::new();
    for (k, v) in vars {
        block.extend(k.encode_wide());
        block.push(u16::from(b'='));
        block.extend(v.encode_wide());
        block.push(0);
    }
    block.push(0);
    block
}

/// Frees a process/thread attribute list on drop.
struct AttributeList(Vec<u8>);

impl AttributeList {
    /// One attribute: the handles the child inherits.
    fn handle_list(handles: &[HANDLE]) -> std::io::Result<Self> {
        let mut size = 0usize;
        // SAFETY: the size query; it fails with ERROR_INSUFFICIENT_BUFFER.
        unsafe { InitializeProcThreadAttributeList(null_mut(), 1, 0, &mut size) };
        let mut list = AttributeList(vec![0u8; size]);
        // SAFETY: a buffer of the size just asked.
        if unsafe { InitializeProcThreadAttributeList(list.ptr(), 1, 0, &mut size) } == 0 {
            list.0.clear();
            return Err(std::io::Error::last_os_error());
        }
        // SAFETY: an initialized list; `handles` outlives CreateProcessW
        // (the caller keeps it alive until the spawn returns).
        if unsafe {
            UpdateProcThreadAttribute(
                list.ptr(),
                0,
                PROC_THREAD_ATTRIBUTE_HANDLE_LIST as usize,
                handles.as_ptr().cast(),
                std::mem::size_of_val(handles),
                null_mut(),
                null(),
            )
        } == 0
        {
            return Err(std::io::Error::last_os_error());
        }
        Ok(list)
    }

    fn ptr(&mut self) -> LPPROC_THREAD_ATTRIBUTE_LIST {
        self.0.as_mut_ptr().cast()
    }
}

impl Drop for AttributeList {
    fn drop(&mut self) {
        if !self.0.is_empty() {
            // SAFETY: initialized in `handle_list`.
            unsafe { DeleteProcThreadAttributeList(self.ptr()) };
        }
    }
}

/// Starts `<exe> [prefix] daemon run --ready-fd <handle>` (see the module
/// comment) and returns the read end of its readiness pipe.
pub(super) fn spawn_detached(home: &Path, prefix: &[OsString]) -> Result<File> {
    let exe = std::env::current_exe()?;
    std::fs::create_dir_all(home)?;
    let log_path = home.join("daemon.log");
    // Owner-only, as on Unix: the log can carry agent output and requests.
    let log = crate::owner_only::open_append(&log_path)
        .with_context(|| format!("open {}", log_path.display()))?;
    let log_err = log.try_clone()?;
    let nul = std::fs::OpenOptions::new().read(true).open("NUL").context("open NUL")?;
    let (reader, writer) = pipe().context("pipe for acpmux daemon readiness")?;
    let inherited: [HANDLE; 4] =
        [writer.as_raw_handle(), nul.as_raw_handle(), log.as_raw_handle(), log_err.as_raw_handle()];
    // Inheritable only so the handle list may name them; the list keeps
    // every other inheritable handle of this process out of the child.
    for handle in inherited {
        set_inherit(handle, true).context("prepare the daemon's handles")?;
    }
    let mut line = Vec::new();
    push_arg(&mut line, exe.as_os_str());
    for arg in prefix {
        push_arg(&mut line, arg);
    }
    for arg in ["daemon", "run", "--ready-fd"] {
        push_arg(&mut line, OsStr::new(arg));
    }
    push_arg(&mut line, OsStr::new(&(writer.as_raw_handle() as isize).to_string()));
    line.push(0);
    let environment = environment_block(home);
    let application: Vec<u16> = exe.as_os_str().encode_wide().chain([0]).collect();
    // The daemon's own folder (it changes to it at start anyway): on
    // Windows a process's current folder cannot be removed or renamed.
    let folder: Vec<u16> = home.as_os_str().encode_wide().chain([0]).collect();
    let mut attributes = AttributeList::handle_list(&inherited)?;
    // SAFETY: plain data; every field the call reads is set below.
    let mut startup: STARTUPINFOEXW = unsafe { std::mem::zeroed() };
    startup.StartupInfo.cb = std::mem::size_of::<STARTUPINFOEXW>() as u32;
    startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    startup.StartupInfo.hStdInput = nul.as_raw_handle();
    startup.StartupInfo.hStdOutput = log.as_raw_handle();
    startup.StartupInfo.hStdError = log_err.as_raw_handle();
    startup.lpAttributeList = attributes.ptr();
    let flags = CREATE_NO_WINDOW
        | CREATE_NEW_PROCESS_GROUP
        | CREATE_UNICODE_ENVIRONMENT
        | EXTENDED_STARTUPINFO_PRESENT;
    let spawn = |flags: u32, line: &mut Vec<u16>| -> std::io::Result<PROCESS_INFORMATION> {
        // SAFETY: plain data, written by the call.
        let mut info: PROCESS_INFORMATION = unsafe { std::mem::zeroed() };
        // SAFETY: NUL-terminated strings and block; `startup` and the
        // attribute list stay alive across the call.
        let ok = unsafe {
            CreateProcessW(
                application.as_ptr(),
                line.as_mut_ptr(),
                null(),
                null(),
                1,
                flags,
                environment.as_ptr().cast(),
                folder.as_ptr(),
                &startup.StartupInfo,
                &mut info,
            )
        };
        if ok == 0 { Err(std::io::Error::last_os_error()) } else { Ok(info) }
    };
    // Out of this process's job when the job allows it; a job that does not
    // refuses the flag with ERROR_ACCESS_DENIED.
    let info = match spawn(flags | CREATE_BREAKAWAY_FROM_JOB, &mut line) {
        Err(e) if e.raw_os_error() == Some(ERROR_ACCESS_DENIED as i32) => spawn(flags, &mut line),
        other => other,
    }
    .map_err(|e| anyhow!("spawn acpmux daemon: {e}"))?;
    // SAFETY: handles CreateProcessW returned to us.
    unsafe {
        CloseHandle(info.hThread);
        CloseHandle(info.hProcess);
    }
    drop(attributes);
    // Close this process's copy so end of file means the daemon closed it.
    drop(writer);
    Ok(reader)
}
