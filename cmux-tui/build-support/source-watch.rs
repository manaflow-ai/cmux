//! Cargo-only dependency that invalidates cmux-remote's build identity when a
//! new workspace-root source input appears.

#![forbid(unsafe_code)]

pub const ACTIVE: () = ();
