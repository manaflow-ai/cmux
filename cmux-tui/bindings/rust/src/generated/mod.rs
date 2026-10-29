// This file is generated. Do not edit by hand.
// cmux-tui mux protocol 12, IR d60b4d9a4e2b29ec10b92b01dff8f04e076911755afc8c218f2d85410be831e3.
// The emitter owns this layout so generation is independent of the installed rustfmt.

// Serde wire enums mirror the protocol's JSON unions; boxing a large
// variant would only change the public types.
#[allow(clippy::large_enum_variant)]
mod commands;
// Serde wire enums mirror the protocol's JSON unions; boxing a large
// variant would only change the public types.
#[allow(clippy::large_enum_variant)]
mod events;
mod metadata;
// Serde wire enums mirror the protocol's JSON unions; boxing a large
// variant would only change the public types.
#[allow(clippy::large_enum_variant)]
mod types;

pub use commands::*;
pub use events::*;
pub use metadata::*;
pub use types::*;
