//! The laptop's side of the Cloud. Owned by slice B (the laptop daemon).
//!
//! [`start`] runs the holder loop ([`super::runtime`]) for a laptop's daemon: as `device:<id>`
//! ([`device`]), over the owner's transport (`cmux_cloud_api::auto_sessions::OwnerAutoCloud`,
//! signed in as the person through the cmux app, [`sign_in`]), with the system's clock, this
//! machine's network notices and the setting `cloud.autoMode` for new chats.
//!
//! What only a laptop does is the state machine's laptop half, run by the loop: it stops a
//! chat's process tree when no renewal was answered for
//! `cmux_auto_session::consts::SELF_STOP_MS` or the system woke (`_acpmux/auto_session/wake`,
//! and a wall-clock jump the loop sees itself), kills the tree of a chat the Cloud took, and
//! keeps what that tree wrote since the last snapshot as a leftover patch
//! ([`super::export::leftover`]).

mod device;
mod sign_in;

use std::sync::Arc;

use cmux_auto_session::holder::ImportReason;
use cmux_auto_session::wire::{Holder, SessionView};
use cmux_cloud_api::auto_sessions::OwnerAutoCloud;
use futures::future::BoxFuture;

use super::runtime::SystemClock;
use super::{
    HolderHandle, HolderOptions, ImportError, Imported, SessionImporter, spawn_holder_with,
};
use crate::hub::Hub;
use crate::user_settings::{self, Settings};

/// The setting that switches Auto on for every new chat.
const AUTO_MODE_SETTING: &str = "cloud.autoMode";

/// Whether a chat made now starts with Auto on: the settings file is read when the chat is
/// made, so a change of the setting needs no restart. A file that cannot be read keeps Auto off.
fn auto_for_new_chats() -> bool {
    match user_settings::read() {
        Settings::Parsed(document) => user_settings::value(&document, AUTO_MODE_SETTING)
            .and_then(|value| value.as_bool())
            .unwrap_or(false),
        Settings::Missing | Settings::Unreadable(_) => false,
    }
}

/// The importer of a build that has none: every handback fails, and the chat stays where the
/// Cloud has it. The Cloud machine slice's importer ([`super::import`]) takes its place.
pub struct NoImporter;

impl SessionImporter for NoImporter {
    fn import<'a>(
        &'a self,
        _session: &'a SessionView,
        _reason: ImportReason,
    ) -> BoxFuture<'a, Result<Imported, ImportError>> {
        Box::pin(async {
            Err(ImportError::Local("this build cannot bring a chat in from the Cloud".to_owned()))
        })
    }
}

/// Starts Auto mode on a laptop's daemon. None on a Cloud machine, whose own side starts the
/// loop ([`super::machine`]), and when this machine has no id to hold a chat under.
///
/// Nothing is asked of the Cloud until a chat has Auto on.
pub fn start(hub: Arc<Hub>, importer: Arc<dyn SessionImporter>) -> Option<HolderHandle> {
    if crate::cloud_host::is_cloud_vm() {
        return None;
    }
    let device = match device::id() {
        Ok(device) => device,
        Err(error) => {
            tracing::warn!("auto session: this machine has no device id: {error:#}");
            return None;
        }
    };
    let asks = hub.scope.child("auto-session sign-in");
    let cloud = Arc::new(OwnerAutoCloud::new(sign_in::AppSignIn::from_env(asks)));
    let options = HolderOptions {
        clock: Arc::new(SystemClock),
        network: Some(crate::peer::network::changes()),
        new_chats: Some(Arc::new(auto_for_new_chats)),
    };
    Some(spawn_holder_with(hub, cloud, Holder::device(device), importer, options))
}
