//! Generated private protocol-v12 escape hatch.
//!
//! New applications should use the handwritten resource handles at the crate
//! root. This module exists for protocol tooling and features that have not
//! acquired a resource-level operation.

pub use crate::client::{
    ClientConfig, CmuxClient as Client, CmuxError as Error, CmuxStream as Stream, Result,
    ServerInfo, StreamCloser, default_socket_path, env_socket_path,
};
pub use crate::convenience::{AttachBuilder, SubscriptionBuilder};
pub use crate::generated::*;
pub use crate::presence::{Nullable, Optional};
pub use crate::raw_support::{
    CommandMetadata, EventMetadata, ProfileMetadata, RequiredNullable, StreamMetadata,
};
pub use crate::topology::SurfaceContext;
