//! The laptop's side of the Cloud. Owned by slice B (the laptop daemon).
//!
//! [`start`] runs the holder loop ([`super::runtime`]) for a laptop's daemon: as `device:<id>`
//! ([`device`]), over the owner's transport (`cmux_cloud_api::auto_sessions::OwnerAutoCloud`,
//! signed in as the person through the cmux app, [`sign_in`]), with the system's clock, this
//! machine's network notices and AutoCloud's switch (`cloud.autoCloud`) for new chats.
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

use cmux_auto_session::wire::Holder;
use cmux_cloud_api::auto_sessions::OwnerAutoCloud;

use super::import::Importer;
use super::machine::chats_root;
use super::runtime::SystemClock;
use super::{HolderHandle, HolderOptions, SessionImporter, spawn_holder_with};
use crate::hub::Hub;

/// Whether a chat made now starts with Auto on: AutoCloud's switch (`cloud.autoCloud`), the one
/// the place picker's Auto reads too ([`crate::placement::auto_cloud_on`]). The settings file is
/// read when the chat is made, so a change of the setting needs no restart. A file that cannot
/// be read keeps Auto off.
fn auto_for_new_chats() -> bool {
    crate::placement::auto_cloud_on()
}

/// Starts Auto mode on a laptop's daemon. None on a Cloud machine, whose own side starts the
/// loop ([`super::machine`]), and when this machine has no id to hold a chat under.
///
/// A chat comes home through the importer ([`super::import`]) over the same transport the
/// loop renews with. One that is new to this laptop (started from the phone with the laptop
/// off) gets its folder where a Cloud machine puts it, `~/Projects/auto/<chat id>`
/// ([`chats_root`]): a clone of its own, not a worktree under `~/.cmux/worktrees`, whose
/// folders are trusted without asking.
///
/// The Cloud is asked once at the start for the person's Auto chats this laptop does not have
/// (`runtime/away.rs`); after that, nothing is asked until a chat has Auto on.
pub fn start(hub: Arc<Hub>) -> Option<HolderHandle> {
    if crate::cloud_host::is_cloud_vm() {
        return None;
    }
    let device = match device::id() {
        Ok(device) => device,
        Err(error) => {
            tracing::warn!("auto session: this machine has no device id: {error:#}");
            // No loop will say which chats are this machine's: none is frozen for it.
            hub.auto_release_all();
            return None;
        }
    };
    let asks = hub.scope.child("auto-session sign-in");
    let cloud = Arc::new(OwnerAutoCloud::new(sign_in::AppSignIn::from_env(asks)));
    let importer: Arc<dyn SessionImporter> =
        Importer::new(Arc::clone(&hub), Arc::clone(&cloud), chats_root());
    let options = HolderOptions {
        clock: Arc::new(SystemClock),
        network: Some(crate::peer::network::changes()),
        new_chats: Some(Arc::new(auto_for_new_chats)),
    };
    Some(spawn_holder_with(hub, cloud, Holder::device(device), importer, options))
}
