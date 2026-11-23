//! The link controller's timing constants, copied from `LinkController.swift` (and the one in
//! `LinkMachine.swift`) as they stand. Nothing here uses them yet: the Swift controller still owns
//! its timers. They become timer effects of [`super::step`] in the follow-up.

use std::time::Duration;

/// A foreground link quiet this long is probed. `LinkController.heartbeat`,
/// `LinkController.swift:47`.
pub const HEARTBEAT: Duration = Duration::from_millis(2500);
/// A foreground probe's timeout. `LinkController.probeTimeout`, `LinkController.swift:48`.
pub const PROBE_TIMEOUT: Duration = Duration::from_secs(2);
/// The heartbeat in the background. `LinkController.backgroundHeartbeat`,
/// `LinkController.swift:49`.
pub const BACKGROUND_HEARTBEAT: Duration = Duration::from_secs(15);
/// A background probe's timeout. `LinkController.backgroundProbeTimeout`,
/// `LinkController.swift:50`.
pub const BACKGROUND_PROBE_TIMEOUT: Duration = Duration::from_secs(8);
/// The probe after a foreground or resume. `LinkController.foregroundProbeTimeout`,
/// `LinkController.swift:53`.
pub const FOREGROUND_PROBE_TIMEOUT: Duration = Duration::from_millis(2000);
/// The quick probe after presence changed under the link (`Effect::QuickProbe`).
/// `LinkController.presenceProbeTimeout`, `LinkController.swift:58`.
pub const PRESENCE_PROBE_TIMEOUT: Duration = Duration::from_millis(1500);
/// Beyond a probe's own timeout, how long the bound around it waits. `LinkController.probeGrace`,
/// `LinkController.swift:60`.
pub const PROBE_GRACE: Duration = Duration::from_millis(500);
/// The gap between standby probes. `LinkController.standbyProbeEvery`, `LinkController.swift:72`.
pub const STANDBY_PROBE_EVERY: Duration = Duration::from_millis(250);
/// One standby probe's timeout. `LinkController.standbyProbeTimeout`, `LinkController.swift:73`.
pub const STANDBY_PROBE_TIMEOUT: Duration = Duration::from_secs(1);
/// How long a silent standby link is kept. `LinkController.standbyLimit`,
/// `LinkController.swift:77`.
pub const STANDBY_LIMIT: Duration = Duration::from_secs(45);
/// The probes that fill [`STANDBY_LIMIT`], one per probe and gap (36).
/// `LinkController.standbyProbes`, `LinkController.swift:79`.
pub const STANDBY_PROBES: u32 = (STANDBY_LIMIT.as_millis()
    / (STANDBY_PROBE_TIMEOUT.as_millis() + STANDBY_PROBE_EVERY.as_millis()))
    as u32;
/// How long a roam waits for a burst of path updates to end. `LinkController.networkSettle`,
/// `LinkController.swift:180`.
pub const NETWORK_SETTLE: Duration = Duration::from_millis(150);
/// How far past a beat a wake still counts as on it (Align Keepalives).
/// `LinkController.beatTolerance`, `LinkController.swift:553`.
pub const BEAT_TOLERANCE: Duration = Duration::from_millis(50);
/// How long a link may stay down before terminals say the Mac is offline (twice this for a first
/// dial). `LinkMachine.Phase.offlineAfter`, `LinkMachine.swift:347`.
pub const OFFLINE_AFTER: Duration = Duration::from_secs(4);
