// This file is generated. Do not edit by hand.
// cmux-tui mux protocol 12, IR ddab6779c50f2a11dadad954b29a4534271986163c5109a9fe0ccc23a70f305b.
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
