//! The daemon outranks the work it supervises (RFD 0049 "acpmux under duress", rule R3): on a host
//! at load 10x its cores, `acpmux ls`, `send` and `register` still answer fast, whoever the load
//! belongs to.
//!
//! `qos.rs` lowers acpmux's own agents (nice +5 on Linux, +11 for an opted-in class on macOS) and
//! `session_scope.rs` gives their scopes `CPUWeight` 40 or 50, but nothing raised the daemon: on a
//! host whose load is not acpmux's children (builds, tests, other tools) it competed as an equal.
//! So the daemon takes what an unprivileged user can take, each knob best effort:
//!
//! | Knob | Linux | macOS |
//! |---|---|---|
//! | nice | asks [`DAEMON_NICE`], then 0 when it inherited a positive one ([`raise`], before the runtime starts its threads, so they inherit it); refused without `CAP_SYS_NICE` or an `RLIMIT_NICE` that allows it | the same ask; refused without root |
//! | cgroup CPU weight | `CPUWeight=` in `acpmux.service` (`cli/hosts.rs`): ten times its `app.slice` siblings; only where the user manager has the `cpu` controller. A unit acpmux did not write asks for it at start ([`raise_weight_at_runtime`], `systemctl --user set-property --runtime`) | not applicable |
//! | cgroup I/O weight | `IOWeight=` in the unit; only where the user manager has the `io` controller (stock systemd delegates `cpu memory pids`) | not applicable |
//! | OOM order | `oom_rank.rs` (unchanged) | not applicable |
//! | thread QoS | not applicable | every runtime thread and the main thread at `QOS_CLASS_USER_INITIATED` ([`thread_start`]); launchd starts the job at `ProcessType` `Interactive` |
//!
//! A negative nice is inherited by what the daemon starts, so a harness and an agent host start at
//! no better than the default (`cpu_class::start_at_normal`, `qos::enter`) and are lowered from
//! there as before. A knob the kernel refuses leaves the daemon as it was; it starts anyway, and
//! its log says which knobs took in one line ([`Report::line`], `daemon priority: …`).
//!
//! A daemon a CLI starts goes through `acpmux.service` when it is loaded (Linux,
//! `daemon/managed_unit.rs`) or through a login-session launchd job when the CLI runs lowered
//! (macOS, `daemon/login_session.rs`), so it does not inherit an agent's nice. Only a Linux host
//! without the unit spawns it detached, at the caller's nice: the log line then says
//! `inherited nice N from caller`.
//!
//! Not reached: a CLI call (`acpmux ls` from an agent's hook) inherits the agent's lowered nice and
//! cannot undo it without the same privilege; it does little work of its own, the daemon does the
//! work. A `CPUWeight` competes only with the unit's siblings in `app.slice`: a build in an ssh
//! login's `session-N.scope` sits beside the whole user manager, where only nice reaches.

use std::sync::OnceLock;

/// The nice value the daemon asks for first.
pub const DAEMON_NICE: i32 = -5;

/// What one knob did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Knob {
    /// Took: the value it now runs at.
    Took(String),
    /// Asked and refused: what it runs at, and why.
    Refused(String),
    /// Not on this OS or this start.
    NotApplicable(&'static str),
}

impl Knob {
    fn word(&self) -> String {
        match self {
            Knob::Took(v) => format!("took {v}"),
            Knob::Refused(v) => format!("refused, {v}"),
            Knob::NotApplicable(why) => format!("n/a ({why})"),
        }
    }
}

/// Every knob, by name, for the daemon's log line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Report {
    pub knobs: Vec<(&'static str, Knob)>,
}

impl Report {
    /// One line: `daemon priority: nice took -5; cpu.weight took 1000; …`.
    pub fn line(&self) -> String {
        let knobs: Vec<String> =
            self.knobs.iter().map(|(name, knob)| format!("{name} {}", knob.word())).collect();
        format!("daemon priority: {}", knobs.join("; "))
    }
}

/// The nice values to ask for, best first, from where the daemon runs (`was`): [`DAEMON_NICE`],
/// then the default 0 when it inherited a positive one. Never one at or above `was`.
pub fn nice_steps(was: i32) -> Vec<i32> {
    [DAEMON_NICE, 0].into_iter().filter(|step| *step < was).collect()
}

/// The first of [`nice_steps`] that `set` takes, as a knob.
pub fn lower_nice(was: i32, mut set: impl FnMut(i32) -> bool) -> Knob {
    let steps = nice_steps(was);
    if steps.is_empty() {
        return Knob::Took(format!("{was} (already)"));
    }
    for step in &steps {
        if set(*step) {
            return Knob::Took(if *step == DAEMON_NICE {
                step.to_string()
            } else {
                format!("{step} (wanted {DAEMON_NICE})")
            });
        }
    }
    Knob::Refused(refused_nice(was))
}

/// Why a nice stayed. A positive one came from the caller: a CLI under an agent started this
/// daemon detached, where no `acpmux.service` (Linux, `daemon/managed_unit.rs`) or login-session
/// job (macOS, `daemon/login_session.rs`) could start it instead.
fn refused_nice(was: i32) -> String {
    let lowering = "lowering needs CAP_SYS_NICE or RLIMIT_NICE (ulimit -e)";
    if was > 0 {
        format!("inherited nice {was} from caller, kept: {lowering}")
    } else {
        format!("kept {was}: {lowering}")
    }
}

/// A cgroup weight file's knob: its value, or why there is none.
pub fn weight_knob(file: Option<&str>, controller: &'static str) -> Knob {
    match file.map(str::trim) {
        Some(v) if !v.is_empty() => Knob::Took(v.to_owned()),
        _ => Knob::NotApplicable(match controller {
            "cpu" => "no cpu controller in this cgroup",
            _ => "no io controller in this cgroup",
        }),
    }
}

/// The unit the daemon runs as when the user manager started it.
const UNIT: &str = "acpmux.service";
/// `CPUWeight=` and `IOWeight=` in `cli/hosts.rs`'s `SYSTEMD_UNIT`.
pub const UNIT_WEIGHT: u32 = 1000;
/// How long the daemon's start waits on the user manager for [`UNIT_WEIGHT`].
const SET_PROPERTY_BOUND: std::time::Duration = std::time::Duration::from_secs(2);

/// Whether the daemon asks the user manager for [`UNIT_WEIGHT`] at start: it runs in
/// `acpmux.service` and its cgroup reads below it. A unit acpmux did not write (an enroll tool's,
/// a hand-written one) has no `CPUWeight=`, and `hosts::unit_refresh` replaces only its own old
/// texts, so before this such a daemon ran at systemd's 100 beside every `app.slice` sibling
/// (a GCP lane VM and a Freestyle slot, 2026-11-25: `cpu.weight took 100`).
pub fn raise_weight_at_runtime(cgroup: &str, cpu_weight: Option<&str>) -> bool {
    let in_unit = cgroup.rsplit('/').next() == Some(UNIT);
    let below =
        cpu_weight.and_then(|w| w.trim().parse::<u32>().ok()).is_some_and(|w| w < UNIT_WEIGHT);
    in_unit && below
}

/// The cpu.weight knob after asking for [`UNIT_WEIGHT`]: what it reads now, and from what.
pub fn raised_knob(before: Option<&str>, after: Option<&str>) -> Knob {
    let before = before.map(str::trim).unwrap_or("?");
    match after.map(str::trim) {
        Some(now) if now == UNIT_WEIGHT.to_string() => {
            Knob::Took(format!("{now} (raised from {before} at runtime)"))
        }
        Some(now) => Knob::Refused(format!("kept {now}: set-property did not take")),
        None => Knob::Refused(format!("kept {before}: systemctl set-property failed")),
    }
}

static NICE: OnceLock<Knob> = OnceLock::new();

/// Whether `args` (without the program name) start the daemon: `daemon` or `daemon run`.
pub fn is_daemon_run(args: &[std::ffi::OsString]) -> bool {
    let mut words = args.iter().filter(|a| *a != "--json" && *a != "--suppress-reads");
    words.next().is_some_and(|a| a == "daemon") && words.next().is_none_or(|a| a == "run")
}

/// The daemon's nice, raised as far as the kernel lets it. Call it on the main thread before the
/// runtime starts its threads: on Linux nice is per thread and a new thread takes its creator's.
pub fn raise() {
    if !crate::qos::enabled() {
        return;
    }
    let _ = NICE.get_or_init(imp::lower_nice);
    imp::thread_start();
}

/// A runtime thread of the daemon at its start (macOS: user-initiated QoS; else nothing).
pub fn thread_start() {
    if crate::qos::enabled() {
        imp::thread_start();
    }
}

/// What took, read where the daemon runs (call it after [`raise`]).
pub fn report() -> Report {
    if !crate::qos::enabled() {
        return Report { knobs: vec![("all", Knob::NotApplicable("ACPMUX_QOS=off"))] };
    }
    let nice = NICE.get().cloned().unwrap_or(Knob::NotApplicable("raised before the runtime only"));
    let mut knobs = vec![("nice", nice)];
    knobs.extend(imp::os_knobs());
    Report { knobs }
}

#[cfg(unix)]
fn current_nice() -> Option<i32> {
    // `getpriority` answers -1 both for nice -1 and for an error: errno says which.
    // SAFETY: plain syscalls on the calling thread (Linux) or process.
    unsafe {
        *errno() = 0;
        let now = libc::getpriority(libc::PRIO_PROCESS, 0);
        (*errno() == 0).then_some(now)
    }
}

#[cfg(target_os = "linux")]
unsafe fn errno() -> *mut libc::c_int {
    unsafe { libc::__errno_location() }
}
#[cfg(target_os = "macos")]
unsafe fn errno() -> *mut libc::c_int {
    unsafe { libc::__error() }
}

#[cfg(unix)]
fn lower_nice_here() -> Knob {
    let Some(was) = current_nice() else { return Knob::NotApplicable("getpriority failed") };
    // SAFETY: plain syscall on the calling thread (Linux) or process (macOS).
    lower_nice(was, |step| unsafe { libc::setpriority(libc::PRIO_PROCESS, 0, step) } == 0)
}

#[cfg(target_os = "linux")]
mod imp {
    use super::Knob;

    pub(super) fn lower_nice() -> Knob {
        super::lower_nice_here()
    }

    pub(super) fn thread_start() {}

    /// `systemctl --user set-property --runtime acpmux.service CPUWeight=… IOWeight=…`, within
    /// [`super::SET_PROPERTY_BOUND`]: the user manager applies it to the running cgroup, restarts
    /// nothing and keeps it until the user manager stops (a reboot), so each start asks again.
    fn set_unit_weight() -> bool {
        let weight = super::UNIT_WEIGHT;
        let Ok(mut child) = cmux_process::Command::new("systemctl")
            .args(["--user", "set-property", "--runtime", super::UNIT])
            .arg(format!("CPUWeight={weight}"))
            .arg(format!("IOWeight={weight}"))
            .stdin(cmux_process::Stdio::null())
            .stdout(cmux_process::Stdio::null())
            .stderr(cmux_process::Stdio::null())
            .spawn()
        else {
            return false;
        };
        // Past the bound the `Child` drops here and ends with it.
        matches!(child.wait_timeout(super::SET_PROPERTY_BOUND), Ok(Some(status)) if status.success())
    }

    /// The unified hierarchy's path of this process (`0::/user.slice/…`).
    fn own_cgroup() -> Option<String> {
        let text = std::fs::read_to_string("/proc/self/cgroup").ok()?;
        text.lines().find_map(|l| l.strip_prefix("0::")).map(str::to_owned)
    }

    pub(super) fn os_knobs() -> Vec<(&'static str, Knob)> {
        let Some(path) = own_cgroup() else {
            return vec![("cgroup", Knob::NotApplicable("no unified cgroup"))];
        };
        let read =
            |file: &str| std::fs::read_to_string(format!("/sys/fs/cgroup{path}/{file}")).ok();
        let before = read("cpu.weight");
        let mut cpu = super::weight_knob(before.as_deref(), "cpu");
        if super::raise_weight_at_runtime(&path, before.as_deref()) {
            let after = set_unit_weight().then(|| read("cpu.weight")).flatten();
            cpu = super::raised_knob(before.as_deref(), after.as_deref());
        }
        vec![
            ("cpu.weight", cpu),
            ("io.weight", super::weight_knob(read("io.weight").as_deref(), "io")),
            ("cgroup", Knob::Took(path)),
        ]
    }
}

#[cfg(target_os = "macos")]
mod imp {
    use super::Knob;

    pub(super) fn lower_nice() -> Knob {
        super::lower_nice_here()
    }

    pub(super) fn thread_start() {
        // SAFETY: plain call on the calling thread with a valid class and relative priority 0.
        unsafe {
            libc::pthread_set_qos_class_self_np(libc::qos_class_t::QOS_CLASS_USER_INITIATED, 0)
        };
    }

    pub(super) fn os_knobs() -> Vec<(&'static str, Knob)> {
        let mut qos = libc::qos_class_t::QOS_CLASS_UNSPECIFIED;
        let mut rel = 0;
        // SAFETY: reads the calling thread's own class into locals.
        unsafe { libc::pthread_get_qos_class_np(libc::pthread_self(), &mut qos, &mut rel) };
        // libc's `qos_class_t` has no `PartialEq`.
        let thread = if matches!(qos, libc::qos_class_t::QOS_CLASS_USER_INITIATED) {
            Knob::Took("user-initiated".into())
        } else {
            Knob::Refused(format!("thread class {}", qos as u32))
        };
        let base = match crate::qos::lowered_priority() {
            Some(p) => Knob::Refused(format!("{p}, below {}", crate::qos::DAEMON_PRIORITY)),
            None => Knob::Took(format!("at least {}", crate::qos::DAEMON_PRIORITY)),
        };
        vec![("thread qos", thread), ("base priority", base)]
    }
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
mod imp {
    use super::Knob;
    pub(super) fn lower_nice() -> Knob {
        Knob::NotApplicable("not unix")
    }
    pub(super) fn thread_start() {}
    pub(super) fn os_knobs() -> Vec<(&'static str, Knob)> {
        Vec::new()
    }
}

#[cfg(test)]
#[path = "daemon_priority_tests.rs"]
mod tests;
