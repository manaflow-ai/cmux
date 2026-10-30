// This file is generated. Do not edit by hand.
// cmux-tui mux protocol 12, IR 8f80374032a2b43588dbfd1be8e1a7ad20218568b41a2e09ba654a7601ef4977.
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
