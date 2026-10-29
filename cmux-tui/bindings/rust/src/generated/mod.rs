// This file is generated. Do not edit by hand.
// cmux-tui mux protocol 12, IR ee51444323390a000bdca12a806fb88329d85c65fda2e5e78181306c44747122.
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
