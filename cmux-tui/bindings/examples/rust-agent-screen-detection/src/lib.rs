//! Reference userland agent plugin.
//!
//! The daemon supervises this process, but all agent-specific policy lives
//! here. The package can be replaced by another implementation that emits
//! the same generic journal envelope.

pub mod detect;
pub mod diagnostics;
pub mod manifest;
pub mod manifest_update;
pub mod process;
pub mod scanner;
