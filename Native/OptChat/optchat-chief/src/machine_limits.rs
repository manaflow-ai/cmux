//! The machine's own limit on helpers (subagents) a Chief starts at once.
//!
//! On 2026-11-23 a Chief-driven Mac (M5 Pro, 15 cores, 48 GB) sat at load
//! 267-320 with 0% idle, 21.3 of 22.5 GB swap used and 1171 processes:
//! 27 `claude` helpers, 118 `swift-frontend`, 28 tagged DEV apps. Leo
//! (2026-11-24): cap helpers and builds per machine. This is a LIMIT, not a
//! refusal: a helper over it is queued (`a<N>: queued, #k in line`) and starts
//! when a slot frees or the machine has room again. Nothing is ever refused.
//!
//! Two rules, both from the machine itself:
//! - the ceiling, always: `max(2, min(2 x cores, RAM GiB / 2))` helpers at work.
//!   Cores are the performance cores (cmux-host-budget's count; 15 on an M5
//!   Pro), RAM the physical memory. 15 cores and 48 GB: min(30, 24) = 24; an
//!   8 GB, 8-core Mac: 4. A helper's session (agent CLI, MCP servers, tool
//!   processes) holds about 1-2 GB while it works, so 2 GB each leaves the
//!   rest of RAM to the app and builds.
//! - the hold, while the machine is over budget (1-minute load at least
//!   2 x cores, or macOS memory pressure warn/critical, or Linux memory PSI
//!   `some avg10` >= 10): no new helper starts while [`FLOOR`] or more work, so
//!   a swapping Mac drains instead of growing. Queued helpers start on the next
//!   tick (60 s) that finds it within budget again.
//!
//! An explicit cap wins: `control cap N` (0 lifts every cap, this one too),
//! then `OPTCHAT_MAX_LIVE_SUBAGENTS=N`. [`ENV`]`=0` turns the machine limit
//! off; [`ENV`]`=N` sets the ceiling to N (the hold still applies). Cloud and
//! peer helpers take no slot here.

/// The env that turns the machine limit off (`0`) or sets its ceiling (`N`).
pub const ENV: &str = "OPTCHAT_MACHINE_HELPERS";

/// Helpers that may always work, even on a machine over budget: a Chief
/// is never stopped from making progress.
pub const FLOOR: usize = 2;

/// The load per core over which no new helper starts.
pub const LOAD_PER_CORE: f64 = 2.0;

/// What the machine is: its cores and its memory.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Machine {
    pub cores: u32,
    pub ram_gib: f64,
}

/// The ceiling for `machine`: `max(FLOOR, min(2 x cores, RAM GiB / 2))`.
pub fn ceiling(machine: Machine) -> usize {
    let by_cores = 2 * machine.cores.max(1) as usize;
    let by_ram = (machine.ram_gib.max(0.0) / 2.0).floor() as usize;
    by_cores.min(by_ram).max(FLOOR)
}

/// The ceiling in force: [`ENV`] unset or not a number takes the formula,
/// `0` means no machine limit (None), `N` is N.
pub fn ceiling_with(env: Option<&str>, machine: Option<Machine>) -> Option<usize> {
    match env.map(str::trim).filter(|v| !v.is_empty()) {
        Some(v) => match v.parse::<usize>() {
            Ok(0) => None,
            Ok(n) => Some(n),
            Err(_) => machine.map(ceiling),
        },
        None => machine.map(ceiling),
    }
}

/// One reading of the machine's load.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Load {
    pub load1: Option<f64>,
    /// macOS `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warn, 4 critical.
    pub vm_pressure_level: Option<u32>,
    /// Linux `/proc/pressure/memory` `some avg10`.
    pub psi_some_avg10: Option<f64>,
}

/// Why the machine is over budget for new helpers, or None when it has room.
pub fn over_budget(machine: Machine, load: Load) -> Option<String> {
    let limit = f64::from(machine.cores.max(1)) * LOAD_PER_CORE;
    if let Some(l) = load.load1.filter(|l| *l >= limit) {
        return Some(format!(
            "load {l:.0} on {} cores (limit {limit:.0})",
            machine.cores
        ));
    }
    match load.vm_pressure_level {
        Some(2) => return Some("memory pressure warn".into()),
        Some(4) => return Some("memory pressure critical".into()),
        _ => {}
    }
    load.psi_some_avg10
        .filter(|p| *p >= 10.0)
        .map(|p| format!("memory pressure (PSI some avg10 {p:.0})"))
}

/// Helpers that may work now: the ceiling, or while over budget no more than
/// are at work already (at least [`FLOOR`]), never above the ceiling.
pub fn allowed(ceiling: usize, live: usize, over: bool) -> usize {
    if over {
        live.max(FLOOR).min(ceiling)
    } else {
        ceiling
    }
}

/// This machine, read once: performance cores (else physical, else logical)
/// and physical memory.
pub fn this_machine() -> Option<Machine> {
    static M: std::sync::OnceLock<Option<Machine>> = std::sync::OnceLock::new();
    *M.get_or_init(|| {
        let sample = cmux_host_budget::Probe::sample(&cmux_host_budget::HostProbe);
        let cores = sample
            .performance_cores
            .or(sample.physical_cores)
            .unwrap_or(sample.logical_cpus)
            .max(1);
        let ram_gib = platform::ram_bytes()? as f64 / f64::from(1u32 << 30);
        Some(Machine { cores, ram_gib })
    })
}

/// The machine's load now (a few sysctls or `/proc` reads: cheap).
pub fn load_now() -> Load {
    let s = cmux_host_budget::Probe::sample(&cmux_host_budget::HostProbe);
    Load {
        load1: s.load1,
        vm_pressure_level: s.vm_pressure_level,
        psi_some_avg10: s.psi_some_avg10,
    }
}

#[cfg(target_os = "macos")]
mod platform {
    pub(super) fn ram_bytes() -> Option<u64> {
        let mut value: u64 = 0;
        let mut size = size_of::<u64>();
        // SAFETY: the name is NUL-terminated and `value`/`size` describe valid storage.
        let ok = unsafe {
            libc::sysctlbyname(
                c"hw.memsize".as_ptr(),
                (&raw mut value).cast(),
                &raw mut size,
                std::ptr::null_mut(),
                0,
            )
        } == 0;
        (ok && value > 0).then_some(value)
    }
}

#[cfg(not(target_os = "macos"))]
mod platform {
    pub(super) fn ram_bytes() -> Option<u64> {
        let text = std::fs::read_to_string("/proc/meminfo").ok()?;
        super::mem_total_bytes(&text)
    }
}

/// `/proc/meminfo`'s MemTotal in bytes.
#[cfg_attr(target_os = "macos", allow(dead_code))]
fn mem_total_bytes(text: &str) -> Option<u64> {
    let kb: u64 = text
        .lines()
        .find_map(|l| l.strip_prefix("MemTotal:"))?
        .trim()
        .trim_end_matches("kB")
        .trim()
        .parse()
        .ok()?;
    (kb > 0).then_some(kb * 1024)
}

#[cfg(test)]
mod tests {
    use super::*;

    const LUCAS: Machine = Machine {
        cores: 15,
        ram_gib: 48.0,
    };

    #[test]
    fn the_ceiling_is_the_smaller_of_cores_and_ram() {
        assert_eq!(ceiling(LUCAS), 24, "min(30, 24)");
        assert_eq!(
            ceiling(Machine {
                cores: 8,
                ram_gib: 8.0
            }),
            4
        );
        assert_eq!(
            ceiling(Machine {
                cores: 32,
                ram_gib: 256.0
            }),
            64
        );
        assert_eq!(
            ceiling(Machine {
                cores: 1,
                ram_gib: 2.0
            }),
            FLOOR,
            "never under the floor"
        );
        assert_eq!(
            ceiling(Machine {
                cores: 0,
                ram_gib: 0.0
            }),
            FLOOR
        );
    }

    #[test]
    fn the_env_overrides_or_turns_it_off() {
        assert_eq!(ceiling_with(None, Some(LUCAS)), Some(24));
        assert_eq!(ceiling_with(Some(""), Some(LUCAS)), Some(24));
        assert_eq!(ceiling_with(Some("0"), Some(LUCAS)), None);
        assert_eq!(ceiling_with(Some(" 6 "), Some(LUCAS)), Some(6));
        assert_eq!(ceiling_with(Some("lots"), Some(LUCAS)), Some(24));
        assert_eq!(
            ceiling_with(None, None),
            None,
            "an unreadable machine has no limit"
        );
    }

    #[test]
    fn the_overloaded_mac_is_over_budget() {
        let load = Load {
            load1: Some(300.0),
            ..Load::default()
        };
        assert!(over_budget(LUCAS, load).unwrap().contains("load 300"));
        let busy = Load {
            load1: Some(29.0),
            vm_pressure_level: Some(1),
            ..Load::default()
        };
        assert_eq!(over_budget(LUCAS, busy), None, "29 < 2 x 15");
        let swapping = Load {
            load1: Some(3.0),
            vm_pressure_level: Some(4),
            ..Load::default()
        };
        assert!(over_budget(LUCAS, swapping).unwrap().contains("critical"));
        let psi = Load {
            psi_some_avg10: Some(12.0),
            ..Load::default()
        };
        assert!(over_budget(LUCAS, psi).is_some());
        assert_eq!(
            over_budget(LUCAS, Load::default()),
            None,
            "no readings: room"
        );
    }

    #[test]
    fn over_budget_holds_at_what_works_never_below_the_floor() {
        assert_eq!(allowed(24, 10, false), 24);
        assert_eq!(allowed(24, 10, true), 10, "no new start");
        assert_eq!(allowed(24, 0, true), FLOOR, "a Chief always makes progress");
        assert_eq!(allowed(24, 30, true), 24, "never above the ceiling");
        assert_eq!(allowed(1, 0, true), 1);
    }

    #[test]
    fn meminfo_total() {
        assert_eq!(
            mem_total_bytes("MemTotal:       16384 kB\nMemFree: 1 kB\n"),
            Some(16384 * 1024)
        );
        assert_eq!(mem_total_bytes("MemFree: 1 kB\n"), None);
    }
}
