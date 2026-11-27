//! "What you can get": the part of the "where you are" card ([`super`]) and of
//! `cmux capabilities` that says what an agent can have beyond this machine, what it costs, how
//! long it takes, and how to ask for it. One source for both.
//!
//! Leo (2026-11-25): "but what if we want even more than the 32vcpu machines? how can an agent
//! know/ask for more capacity?", then "when they're on the vm that is".
//!
//! Every number is copied from the catalog that sets it, never guessed; a test pins the copy:
//! - Shapes: `web/services/vms/images/sizes.ts` `VM_IMAGE_SIZES` (Freestyle's ladder plus cmux's
//!   derived 24 GiB row). Plan caps: `backend/apps/api/src/domains/cloud-plan.ts`
//!   `PAID_PLAN_LIMITS` (Plus, Pro, Founders and Team stop at 8 vCPU / 16 GiB and a 128 GiB
//!   disk; Max reaches 32 vCPU / 64 GiB and a 256 GiB disk; 5 running machines at once).
//! - Price: [`crate::hub::turn_cost`]'s list rates, the ones a turn's compute cost uses.
//! - Time: a new machine boots and its guest is ready in about 12 s
//!   (`plans/cmux-next/cloud-environments-DESIGN.md` section 9: 6.2 + 6.2 s and 6.4 + 5.7 s);
//!   a fork of this machine is p50 37 s ([`crate::placement::sub_fork::FORK_BUDGET`]'s note,
//!   cmux#54532).
//! - GPU: none (`web/services/vms/autosize.ts` answers `gpu_unavailable`, "No cloud machine has
//!   a GPU yet."). Mac: Cloud's providers (Freestyle, GCP) run Linux only.
//!
//! The asking command, `cmux machine request`, belongs to the placer (RFD agent-work-placement);
//! [`MACHINE_REQUEST_ON_THIS_BUILD`] says whether this build has it, and the card says plainly
//! when it does not.

use serde::Serialize;

/// Whether this build's `cmux` has `cmux machine request`. The placer's PR that adds the command
/// to `cmux machine --help` (cmux-tui `MACHINE_HELP`) flips it.
pub const MACHINE_REQUEST_ON_THIS_BUILD: bool = false;

/// How an agent asks for more than it has.
pub const REQUEST_COMMAND: &str =
    "cmux machine request --vcpu N --mem M [--fanout K] [--kind mac|gpu] --for \"why\" --until ...";

/// One Cloud machine size.
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
pub struct Shape {
    /// The ladder's name (`sizes.ts`).
    pub name: &'static str,
    pub vcpus: u32,
    pub memory_gib: u32,
    /// The disk a new machine of this size starts with; it grows up to the plan's cap.
    pub disk_gib: u32,
    /// The lowest plan that can start it.
    pub plan: &'static str,
}

/// `VM_IMAGE_SIZES`, smallest first.
pub const LADDER: &[Shape] = &[
    Shape { name: "sm", vcpus: 2, memory_gib: 4, disk_gib: 16, plan: "pro" },
    Shape { name: "md", vcpus: 4, memory_gib: 8, disk_gib: 32, plan: "pro" },
    Shape { name: "lg", vcpus: 8, memory_gib: 16, disk_gib: 64, plan: "pro" },
    Shape { name: "lgx", vcpus: 12, memory_gib: 24, disk_gib: 96, plan: "max" },
    Shape { name: "xl", vcpus: 16, memory_gib: 32, disk_gib: 128, plan: "max" },
    Shape { name: "2xl", vcpus: 32, memory_gib: 64, disk_gib: 128, plan: "max" },
];

/// The top of the ladder (a const index: the compiler checks it).
pub const LARGEST: Shape = LADDER[LADDER.len() - 1];
/// The largest size below Max (`lg`); a test keeps it the last non-Max row.
pub const LARGEST_BELOW_MAX: Shape = LADDER[2];

/// `PAID_PLAN_LIMITS`: the most running machines a paid plan has at once.
pub const MACHINES_AT_ONCE: u32 = 5;
/// `PAID_PLAN_LIMITS` disk caps, GiB.
pub const PRO_DISK_GIB: u32 = 128;
pub const MAX_DISK_GIB: u32 = 256;
/// A new machine, boot plus guest ready (cloud-environments-DESIGN.md section 9).
pub const NEW_MACHINE_SECONDS: u32 = 12;
/// A fork of this machine, p50 (cmux#54532, n=5).
pub const FORK_SECONDS_P50: u32 = 37;

/// One size with its price.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Priced {
    #[serde(flatten)]
    pub shape: Shape,
    /// List price while it runs, USD an hour, to the cent.
    pub usd_per_hour: f64,
}

/// A tier that does not exist yet, and why.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Tier {
    pub available: bool,
    pub why: &'static str,
}

/// How to ask for more.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Request {
    pub command: &'static str,
    pub on_this_build: bool,
    /// What to do until the command is on this build.
    pub until_then: &'static str,
}

/// What an agent can get beyond this machine.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct CanGet {
    pub sizes: Vec<Priced>,
    pub largest: Priced,
    /// The largest Plus, Pro, Founders or Team machine.
    pub largest_below_max: Priced,
    pub new_machine_seconds: u32,
    pub machines_at_once: u32,
    pub fanout_vcpus: u32,
    pub disk_gib_max: u32,
    pub disk_gib_below_max: u32,
    /// A working sub-session runs on its own fork of this machine (`sub_fork`).
    pub sub_session_forks: bool,
    pub fork_seconds_p50: u32,
    pub mac: Tier,
    pub gpu: Tier,
    pub request: Request,
}

fn priced(shape: Shape) -> Priced {
    let per_hour = crate::hub::turn_cost::compute_usd_per_second(
        f64::from(shape.vcpus),
        f64::from(shape.memory_gib),
    ) * 3600.0;
    Priced { shape, usd_per_hour: (per_hour * 100.0).round() / 100.0 }
}

impl CanGet {
    /// The catalog, with whether sub-sessions fork on this machine (the same test the
    /// placement uses: AutoCloud's sub-fork switch on and a Cloud machine id).
    pub fn read() -> Self {
        Self::with_forks(
            crate::placement::sub_fork::enabled()
                && crate::placement::sub_fork::this_machine().is_some(),
        )
    }

    pub fn with_forks(sub_session_forks: bool) -> Self {
        let sizes: Vec<Priced> = LADDER.iter().copied().map(priced).collect();
        let largest = priced(LARGEST);
        let largest_below_max = priced(LARGEST_BELOW_MAX);
        CanGet {
            fanout_vcpus: largest.shape.vcpus * MACHINES_AT_ONCE,
            sizes,
            largest,
            largest_below_max,
            new_machine_seconds: NEW_MACHINE_SECONDS,
            machines_at_once: MACHINES_AT_ONCE,
            disk_gib_max: MAX_DISK_GIB,
            disk_gib_below_max: PRO_DISK_GIB,
            sub_session_forks,
            fork_seconds_p50: FORK_SECONDS_P50,
            mac: Tier { available: false, why: "Cloud machines are Linux only (Freestyle, GCP)." },
            gpu: Tier { available: false, why: "No Cloud machine has a GPU yet." },
            request: Request {
                command: REQUEST_COMMAND,
                on_this_build: MACHINE_REQUEST_ON_THIS_BUILD,
                until_then: "tell the person what you need and why; they pick a size or a plan",
            },
        }
    }

    /// The card's part: a few lines, the same on every turn of a chat.
    pub fn lines(&self) -> String {
        let l = &self.largest;
        let p = &self.largest_below_max;
        let mut out = format!(
            "What you can get beyond this machine (sizes and prices: `cmux capabilities`):\n\
- One Cloud machine up to {} vCPU, {} GB RAM, {} GB disk on Max (Pro and Team: {} vCPU, {} GB, {} GB), about ${:.2}/h at the top, ready in about {} s.\n",
            l.shape.vcpus,
            l.shape.memory_gib,
            self.disk_gib_max,
            p.shape.vcpus,
            p.shape.memory_gib,
            self.disk_gib_below_max,
            l.usd_per_hour,
            self.new_machine_seconds,
        );
        out.push_str(&format!(
            "- Past one machine: up to {} Cloud machines at once ({} vCPU on Max)",
            self.machines_at_once, self.fanout_vcpus
        ));
        if self.sub_session_forks {
            out.push_str(&format!(
                "; a working sub-session (start_session, worktree: true) gets its own fork of this machine in about {} s",
                self.fork_seconds_p50
            ));
        }
        out.push_str(".\n- No Mac or GPU Cloud machines yet.\n");
        out.push_str(&format!("- To ask for more: `{}`", self.request.command));
        if self.request.on_this_build {
            out.push_str(".\n");
        } else {
            out.push_str(&format!(
                " is not on this build yet; until it is, {}.\n",
                self.request.until_then
            ));
        }
        out
    }

    /// `cmux capabilities`' table: every size with its plan and price.
    pub fn table(&self) -> String {
        let mut out = String::from("Cloud machine sizes (list price while running):\n");
        for s in &self.sizes {
            out.push_str(&format!(
                "- {}: {} vCPU, {} GB RAM, {} GB disk to start, {}+, ${:.2}/h\n",
                s.shape.name,
                s.shape.vcpus,
                s.shape.memory_gib,
                s.shape.disk_gib,
                s.shape.plan,
                s.usd_per_hour
            ));
        }
        out.push_str(&format!(
            "Disk grows in 4 GB steps to {} GB (Max) or {} GB. Mac: {} GPU: {}\n",
            self.disk_gib_max, self.disk_gib_below_max, self.mac.why, self.gpu.why
        ));
        out
    }
}
