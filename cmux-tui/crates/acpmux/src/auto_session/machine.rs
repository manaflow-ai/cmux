//! The Cloud machine's side. Owned by slice C (the Cloud machine daemon).
//!
//! The machine's transport ([`MachineCloud`]): `cmux_auto_session::AutoCloud` through the
//! machine's Cloud agent (cmux-host `cloud/auto_session.rs`), which holds the VM install's
//! bearer. And the assignment reader ([`Machine`]): at start, at resume and while the daemon
//! runs (a held request of at most 25 s) it reads this machine's assignments and tells each to
//! the holder loop, which does its work: import, inbox, ack, renew at work.
//!
//! [`serve`] is the whole side for a daemon on a Cloud machine: it learns the machine's name
//! from the agent, starts the holder loop ([`super::spawn_holder`]) as `vm:<machine>` with the
//! real importer, and reads assignments from then on. Nothing happens to any chat until the
//! store assigns one. The daemon starts it on a Cloud machine only, once the agent's Auto mode
//! socket is there (`daemon/cloud_activity.rs`).
//!
//! A Cloud machine is Linux; the agent's socket is a Unix socket, so the transport builds on
//! Unix only (its tests run on a Mac builder too).

mod assign;
#[cfg(unix)]
mod transport;

use std::path::PathBuf;
use std::sync::Arc;

pub use assign::Machine;
use cmux_auto_session::AutoCloud;
use cmux_auto_session::wire::Holder;
#[cfg(unix)]
pub use transport::{MachineCloud, SOCKET_ENV, socket_path};

use super::import::Importer;
use super::{HolderHandle, HolderOptions, SessionImporter, spawn_holder_with};
use crate::hub::Hub;

/// This machine's side over `cloud`, as the holder `me`: the importer, the holder loop started
/// with it, and the assignment reader to run ([`Machine::run`]). A chat new to this machine
/// gets its folder at `<root>/<chat id>`.
///
/// The reader only reads: it tells the loop each assignment (`HolderHandle::assigned`), and
/// the loop imports, takes the inbox, acks and renews in the chat's own order.
pub fn attach<C: AutoCloud + 'static>(
    hub: Arc<Hub>,
    cloud: Arc<C>,
    me: Holder,
    root: PathBuf,
) -> (Arc<Machine<C>>, HolderHandle) {
    attach_with(hub, cloud, me, root, HolderOptions::default())
}

/// [`attach`] with the holder loop's clock chosen by the caller (a test).
pub fn attach_with<C: AutoCloud + 'static>(
    hub: Arc<Hub>,
    cloud: Arc<C>,
    me: Holder,
    root: PathBuf,
    options: HolderOptions,
) -> (Arc<Machine<C>>, HolderHandle) {
    let importer: Arc<dyn SessionImporter> =
        Importer::new(Arc::clone(&hub), Arc::clone(&cloud), root);
    let holder = spawn_holder_with(hub, Arc::clone(&cloud), me, importer, options);
    let told = holder.clone();
    let machine = Machine::telling(cloud, move |assignment| told.assigned(assignment));
    (machine, holder)
}

/// Where a chat that is new on this machine gets its folder: `~/Projects/auto/<chat id>`.
pub fn chats_root() -> PathBuf {
    dirs::home_dir().unwrap_or_default().join("Projects").join("auto")
}

/// The Cloud machine's side of Auto mode, for as long as the daemon runs. It first waits for
/// the agent to name this machine (the agent binds a moment after a machine starts), asking
/// again on a timer that backs off to a minute.
#[cfg(unix)]
pub async fn serve(hub: Arc<Hub>, cloud: Arc<MachineCloud>, root: PathBuf) {
    use std::time::Duration;
    let mut wait = Duration::from_secs(1);
    let me = loop {
        match cloud.holder().await {
            Ok(me) => break me,
            Err(error) => tracing::debug!("auto mode: the Cloud agent is not ready: {error}"),
        }
        tokio::time::sleep(wait).await;
        wait = (wait * 2).min(Duration::from_secs(60));
    };
    let (machine, _holder) = attach(hub, cloud, me, root);
    machine.run().await
}
