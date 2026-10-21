//! Which acpmux agent session a tools-socket caller runs under (2026-10-19).
//!
//! The turn seal (`chief_profile.rs` `TURN_KEY_ENV`) is a value in an
//! environment, and environments are inherited: a daemon started from a
//! turn's shell gave it to every agent it spawned, and the terminals that
//! shell opened keep it. So the value alone never opens `chiefs`. The caller
//! must also run under one of this Chief's turn sessions:
//!
//! - the socket peer's pid (`acpmux_peer::peer`), then its parents, up to
//!   the nearest process whose parent runs this host's acpmux (an agent host,
//!   or the daemon itself without hosts): that process is the agent;
//! - the agent's own environment, which acpmux set when it spawned it
//!   (`ACPMUX_SESSION_NAME`, agent/command.rs), names its session;
//! - the session is a turn when its name is `<turn prefix><message id>`
//!   (and acpmux's `-<n>` for a taken name), a subagent when it starts with
//!   `<subagent prefix>`; anything else (a turn's acpmux sub-session
//!   `<turn>/<short>` included), or no acpmux agent
//!   among the parents (an orphaned terminal host's shell), is neither.
//!
//! The role comes from that binding, never from the caller's own
//! `"from":"subagent"` (which can only add a refusal). A same-uid process
//! that builds a process tree on purpose can still pass (identity.md
//! section 1: attribution, not a sandbox); a leaked copy of the seal cannot.

use std::path::{Path, PathBuf};

/// How a tools socket binds callers to sessions.
#[derive(Clone, Debug)]
pub struct TurnBinding {
    /// This Chief's turn session names start with it (`optchat-<home id>-`).
    pub turn_prefix: String,
    /// Its subagent session names start with it (`optchat-sub-<home id>-`).
    pub subagent_prefix: String,
    /// The executable that spawns agents (this host's acpmux, symlinks
    /// resolved). None: no caller is bound, so no caller is the turn.
    pub agent_parent: Option<PathBuf>,
}

/// The session role a caller runs under.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Role {
    /// One of this Chief's turn sessions.
    Turn,
    /// One of this Chief's subagents.
    Subagent,
    /// Any other session, or no acpmux agent among the caller's parents.
    Other,
}

/// Most parents walked: agent trees are shallow (agent, shell, tool).
const MAX_DEPTH: usize = 32;

impl TurnBinding {
    /// The binding of a Chief host for `home_id`, with this host's acpmux.
    pub fn for_home(turn_prefix: &str, home_id: &str) -> TurnBinding {
        TurnBinding {
            turn_prefix: format!("{turn_prefix}-"),
            subagent_prefix: format!("optchat-sub-{home_id}-"),
            agent_parent: crate::acpmux_peer::expected(),
        }
    }

    /// The role of the process `pid` (a socket peer).
    pub fn role_of(&self, pid: i32) -> Role {
        let Some(parent_exe) = self.agent_parent.as_deref() else {
            return Role::Other;
        };
        match agent_session_name(pid, parent_exe) {
            Some(name) if self.is_turn_name(&name) => Role::Turn,
            Some(name) if name.starts_with(&self.subagent_prefix) => Role::Subagent,
            _ => Role::Other,
        }
    }
}

impl TurnBinding {
    /// The subagent id (`a12`) of a subagent session name
    /// (`<subagent prefix>a12`, and acpmux's `-<n>` for a taken name); None
    /// for any other name.
    pub fn subagent_id(&self, name: &str) -> Option<String> {
        let id = name
            .strip_prefix(&self.subagent_prefix)?
            .split('-')
            .next()?;
        let digits = id.strip_prefix('a')?;
        (!digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit())).then(|| id.to_owned())
    }

    /// The subagent id (`a<N>`) of the process `pid` when it runs under one
    /// of this Chief's subagent sessions; None for any other caller.
    pub fn subagent_of(&self, pid: i32) -> Option<String> {
        let parent_exe = self.agent_parent.as_deref()?;
        let name = agent_session_name(pid, parent_exe)?;
        name.starts_with(&self.subagent_prefix)
            .then(|| crate::tools::subagent_of_session(&name))
            .flatten()
    }

    /// `<turn prefix><digits>`, then any `-<digits>` acpmux adds to a taken
    /// name (`hub/new_request.rs` `unique_name_among`); nothing else.
    fn is_turn_name(&self, name: &str) -> bool {
        name.strip_prefix(&self.turn_prefix).is_some_and(|rest| {
            rest.split('-')
                .all(|part| !part.is_empty() && part.bytes().all(|b| b.is_ascii_digit()))
        })
    }
}

/// Whether `pid` is this process or runs under it (a native engine's tool
/// child, such as its bash): such a caller acts for the Chief, not the owner.
pub fn under_this_process(pid: i32) -> bool {
    let me = std::process::id() as i32;
    let mut current = pid;
    for _ in 0..MAX_DEPTH {
        if current == me {
            return true;
        }
        match parent_pid(current) {
            Some(parent) if parent > 1 => current = parent,
            _ => return false,
        }
    }
    false
}

/// Whether this process runs under any Chief's subagent session
/// (`optchat-sub-…`, as the host's `subagent_prefix` matches): by the session
/// name acpmux set on the agent above it, or by its own
/// `ACPMUX_SESSION_NAME`. Used where no host answers to bind the caller (the
/// settings and browse CLI's file fallbacks).
pub fn this_process_is_a_subagent() -> bool {
    let named =
        |name: Option<String>| name.is_some_and(|name| name.trim().starts_with("optchat-sub-"));
    named(std::env::var("ACPMUX_SESSION_NAME").ok())
        || crate::acpmux_peer::expected()
            .is_some_and(|acpmux| named(agent_session_name(std::process::id() as i32, &acpmux)))
}

/// The `ACPMUX_SESSION_NAME` of the nearest acpmux agent at or above `pid`.
fn agent_session_name(pid: i32, agent_parent: &Path) -> Option<String> {
    let mut current = pid;
    for _ in 0..MAX_DEPTH {
        let parent = parent_pid(current)?;
        if parent <= 1 {
            return None;
        }
        if executable(parent).is_some_and(|exe| exe == agent_parent) {
            return environment_value(current, "ACPMUX_SESSION_NAME");
        }
        current = parent;
    }
    None
}

#[cfg(target_os = "linux")]
fn parent_pid(pid: i32) -> Option<i32> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    // `pid (comm) state ppid ...`; comm may hold spaces and parentheses.
    let after = &stat[stat.rfind(')')? + 1..];
    after.split_whitespace().nth(1)?.parse().ok()
}

#[cfg(target_os = "macos")]
fn parent_pid(pid: i32) -> Option<i32> {
    // SAFETY: proc_bsdinfo is plain C data; all zero bytes is a valid value.
    let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<libc::proc_bsdinfo>() as libc::c_int;
    // SAFETY: `info` is a writable proc_bsdinfo of `size` bytes.
    let read =
        unsafe { libc::proc_pidinfo(pid, libc::PROC_PIDTBSDINFO, 0, (&raw mut info).cast(), size) };
    (read == size).then_some(info.pbi_ppid as i32)
}

fn executable(pid: i32) -> Option<PathBuf> {
    crate::acpmux_peer::executable_of(pid).ok()
}

#[cfg(target_os = "linux")]
fn environment_value(pid: i32, key: &str) -> Option<String> {
    let bytes = std::fs::read(format!("/proc/{pid}/environ")).ok()?;
    value_in(bytes.split(|b| *b == 0), key)
}

#[cfg(target_os = "macos")]
fn environment_value(pid: i32, key: &str) -> Option<String> {
    let mut argmax: libc::c_int = 0;
    let mut size = std::mem::size_of::<libc::c_int>();
    let mut mib = [libc::CTL_KERN, libc::KERN_ARGMAX];
    // SAFETY: the out buffer is a c_int and `size` is its size.
    let read = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            2,
            (&raw mut argmax).cast(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    if read != 0 || argmax <= 0 {
        return None;
    }
    let mut buffer = vec![0u8; argmax as usize];
    let mut filled = buffer.len();
    let mut mib = [libc::CTL_KERN, libc::KERN_PROCARGS2, pid];
    // SAFETY: the buffer is writable for `filled` bytes, which is passed.
    let read = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            3,
            buffer.as_mut_ptr().cast(),
            &mut filled,
            std::ptr::null_mut(),
            0,
        )
    };
    if read != 0 {
        return None;
    }
    // argc (i32), the exec path, NUL padding, argc arguments, the environment.
    let data = &buffer[..filled];
    let argc = usize::try_from(i32::from_le_bytes(data.get(..4)?.try_into().ok()?)).ok()?;
    let rest = &data[4..];
    let path_end = rest.iter().position(|b| *b == 0)?;
    let start = path_end + rest[path_end..].iter().position(|b| *b != 0)?;
    let mut strings = rest[start..].split(|b| *b == 0);
    if strings.by_ref().take(argc).count() != argc {
        return None;
    }
    value_in(
        strings
            .skip_while(|s| s.is_empty())
            .take_while(|s| !s.is_empty()),
        key,
    )
}

fn value_in<'a>(entries: impl Iterator<Item = &'a [u8]>, key: &str) -> Option<String> {
    let prefix = format!("{key}=");
    entries
        .filter_map(|entry| entry.strip_prefix(prefix.as_bytes()))
        .map(|value| String::from_utf8_lossy(value).into_owned())
        .next()
}
