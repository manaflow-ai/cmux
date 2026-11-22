//! Dev-only prototype: two acpmux pieces hosted as WebAssembly components that a running daemon
//! swaps live, with no restart and no state to move (plans/cmux-next/acpmux-hot-modules-DESIGN.md).
//!
//! The pieces are pure functions of their arguments, acpmux's own source compiled for
//! `wasm32-wasip2` by `guest/` (the files are included, not copied):
//! - [`HotModule::login_offer`]: `agent_login::parse::offer`, the agent-output parser that reads a
//!   sign-in's link and one-time code from an agent CLI's terminal output;
//! - [`HotModule::is_pure_read`]: `write_journal::classify::is_pure_read`, the policy check that
//!   says whether a shell command only reads files.
//!
//! Every call answers `None` when no module is loaded or the module trapped: the caller then runs
//! its native code, so a broken module costs one native call, never a wrong answer from a half-run
//! guest. A trap rolls the slot back to the module before it (or to none) at once.
//!
//! Without the `wasm` feature this crate is these types alone and builds no wasmtime. acpmux's
//! `hot-modules` feature turns `wasm` on; [`daemon`] then reads `ACPMUX_HOT_MODULE` in a debug build
//! only, and never in a shipped one.

#[cfg(feature = "wasm")]
mod host;
#[cfg(feature = "wasm")]
mod trust;

#[cfg(feature = "wasm")]
pub use host::{HotModule, Options, Stats, SwapReport, daemon};

/// The environment variable that names the daemon's module file (debug builds only).
pub const ENV: &str = "ACPMUX_HOT_MODULE";

/// The WIT world's `abi-version`; a module answering another one is refused.
pub const ABI_VERSION: u32 = 1;

/// Which agent CLI's sign-in output [`HotModule::login_offer`] reads (acpmux `agent_login::Agent`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Agent {
    Claude,
    Codex,
}

/// What a started sign-in asks the person to do (acpmux `agent_login::parse::Offer`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Offer {
    pub url: String,
    pub user_code: Option<String>,
}
