//! Auto mode: a chat keeps running on the person's Cloud machine when the laptop goes away, and
//! comes home when it returns (`plans/cmux-next/auto-mode/DESIGN.md`).
//!
//! The rules live in `cmux-auto-session` (wire types, the holder's state machine, chunks, the
//! Cloud store as a trait). This module is the daemon around them, in two halves that meet at
//! the two seams below:
//!
//! - The laptop side (slice B): [`runtime`], [`export`], [`laptop`].
//! - The Cloud machine side (slice C): [`import`], [`machine`].
//!
//! [`SessionImporter`] is implemented by the machine side and called by the laptop side on a
//! handback. [`spawn_holder`] is implemented by the laptop side and called by the machine side
//! with its own transport, so one holder loop serves both.
//!
//! Nothing here runs yet: no task starts and no session changes.

pub mod export;
pub mod import;
pub mod laptop;
pub mod machine;
pub mod runtime;

use std::fmt;
use std::sync::Arc;

use cmux_auto_session::AutoCloud;
use cmux_auto_session::cloud::AutoCloudError;
/// Why a chat is brought into this daemon: `Takeover`, `Handback`, `Create` or `Deliver`. The
/// holder's state machine names it in its `Import` effect.
pub use cmux_auto_session::holder::ImportReason;
use cmux_auto_session::wire::{Holder, SessionView};
use futures::future::BoxFuture;

use crate::hub::Hub;

/// A chat that is now a local session, ready to run.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Imported {
    /// The local session's id (the chat's id in the Cloud).
    pub session_id: String,
    /// The epoch the import ran under.
    pub epoch: u64,
    /// The last event that was imported.
    pub last_seq: u64,
    /// The snapshot that was imported; 0 when the chat had none.
    pub snapshot: u64,
}

/// Why an import did not finish. The chat is not local, or is as it was before.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ImportError {
    /// The Cloud refused a read or did not answer.
    Cloud(AutoCloudError),
    /// The events or the snapshot could not be made into a local session.
    Local(String),
}

impl ImportError {
    /// The same import may succeed later as it is.
    pub fn retryable(&self) -> bool {
        match self {
            ImportError::Cloud(error) => error.retryable(),
            ImportError::Local(_) => false,
        }
    }
}

impl fmt::Display for ImportError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ImportError::Cloud(error) => {
                write!(f, "the chat could not be read from the Cloud: {error}")
            }
            ImportError::Local(text) => write!(f, "the chat could not be imported: {text}"),
        }
    }
}

impl std::error::Error for ImportError {}

impl From<AutoCloudError> for ImportError {
    fn from(error: AutoCloudError) -> ImportError {
        ImportError::Cloud(error)
    }
}

/// Brings a chat's Cloud copy into this daemon as a local session. Implemented by the machine
/// side ([`import`], slice C); the holder loop calls it when the store makes this machine the
/// holder (a handback on a laptop, an assignment on a Cloud machine).
///
/// `session` is the store's view at the moment of the grant; its `epoch` is the one to import
/// under. An import that ran before for the same chat and epoch answers the same again.
pub trait SessionImporter: Send + Sync {
    fn import<'a>(
        &'a self,
        session: &'a SessionView,
        reason: ImportReason,
    ) -> BoxFuture<'a, Result<Imported, ImportError>>;
}

/// The running holder loop of one daemon: it renews the Auto chats this machine holds or stands
/// by for, and runs the state machine's effects. Dropping it does not stop the loop.
#[derive(Clone, Debug)]
pub struct HolderHandle {
    me: Holder,
}

impl HolderHandle {
    /// This machine's holder name (`device:<id>` on a laptop, `vm:<machine>` on a Cloud machine).
    pub fn holder(&self) -> &Holder {
        &self.me
    }
}

/// Starts the holder loop ([`runtime`], slice B). A laptop's daemon calls it with the owner's
/// transport ([`laptop`]) and `device:<id>`; a Cloud machine's daemon calls it with its own
/// transport ([`machine`]) and `vm:<machine>`.
///
/// It starts nothing yet: the handle only keeps the holder's name.
pub fn spawn_holder<C>(
    hub: Arc<Hub>,
    cloud: Arc<C>,
    me: Holder,
    importer: Arc<dyn SessionImporter>,
) -> HolderHandle
where
    C: AutoCloud + 'static,
{
    let _ = (hub, cloud, importer);
    HolderHandle { me }
}
