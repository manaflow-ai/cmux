//! A dev build's cloud data space: `X-Cmux-Build-Space: dev:<slug>`.
//!
//! A dev build sends its tag on every request and WebSocket upgrade to the
//! backend, so dev builds never see each other's data or the data of nightly
//! and stable builds. Nightly, stable and store builds have no build space
//! and send no header at all. The app decides (Swift `CMUXBuildSpace`); this
//! crate only sends it. The value and its rules are cmux-tui's
//! `cmux-build-space`, the one every Rust cloud client of the Mac shares.

pub use cmux_build_space::{BuildSpace, HEADER};
