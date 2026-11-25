//! The phone's LAN direct path (`cmux_mobile_link::lan`) in `connect`.
//!
//! - `set_lan_memory_dir` turns it on: the app names a folder in its own
//!   container, where the phone's LAN key and each Mac's enrollment live.
//!   Until then nothing here runs and `connect` is unchanged.
//! - `race`: with a Mac enrolled, the direct dial runs beside the relayed
//!   one; the first link up wins and the other is dropped. The direct dial
//!   needs no token, socket or ICE, so it works with the internet down.
//! - `enroll_later`: after any link is up, the phone (re-)enrolls its key on
//!   it, which keeps the Mac's addresses fresh. The Mac serves `lan` only
//!   once `auth` proved this phone.

use std::future::Future;
use std::path::PathBuf;
use std::sync::{Mutex, PoisonError};
use std::time::Duration;

use cmux_mobile_link::lan::{self, LanEnrollReply, LanMac, LanMemory};
use cmux_mobile_link::{ChannelEvent, Connected, Link, LinkConfig, Timeline};

use crate::CmuxMobileError;

/// How long enrollment may wait (for `auth` too) before it gives up for
/// this link.
const ENROLL_TIMEOUT: Duration = Duration::from_secs(60);

static MEMORY: Mutex<Option<LanMemory>> = Mutex::new(None);

/// The folder (in the app's own container) where the LAN direct path keeps
/// this phone's key and what each Mac told it; `None` turns the path off.
/// Call once at launch, before `connect`.
#[uniffi::export]
pub fn set_lan_memory_dir(dir: Option<String>) {
    let memory = dir
        .filter(|dir| !dir.trim().is_empty())
        .map(|dir| LanMemory::open(PathBuf::from(dir).join("lan.json")));
    *MEMORY.lock().unwrap_or_else(PoisonError::into_inner) = memory;
}

fn memory() -> Option<LanMemory> {
    MEMORY.lock().unwrap_or_else(PoisonError::into_inner).clone()
}

/// Dial `mac` over the relayed `relay` and, when the phone has it enrolled,
/// directly on the LAN at once; the first link up wins. Returns the link and
/// the relayed dial's extra (its signaling socket) when that one won.
pub(crate) async fn race<S, F>(
    mac: &str,
    timeline: &Timeline,
    relay: F,
) -> Result<(Connected, Option<S>), CmuxMobileError>
where
    F: Future<Output = Result<(Connected, S), CmuxMobileError>>,
{
    let Some(memory) = memory() else {
        return relay.await.map(|(connected, extra)| (connected, Some(extra)));
    };
    let Some(entry) = memory.mac(mac) else {
        return relay.await.map(|(connected, extra)| (connected, Some(extra)));
    };
    let identity = memory.identity();
    let network = lan::network_tag();
    let candidates = entry.candidates(network.as_deref());
    let direct = lan::connect(&identity, &entry, candidates, LinkConfig::default(), timeline);
    tokio::pin!(relay);
    tokio::pin!(direct);
    let mut relay_failed: Option<CmuxMobileError> = None;
    let mut direct_failed = false;
    loop {
        tokio::select! {
            result = &mut direct, if !direct_failed => match result {
                Ok((connected, address)) => {
                    memory.worked(mac, network.as_deref(), address);
                    timeline.mark("lan_won");
                    tracing::info!(%address, "LAN direct link up");
                    return Ok((connected, None));
                }
                Err(error) => {
                    tracing::info!(%error, "LAN direct dial failed; relayed dial continues");
                    timeline.mark("lan_failed");
                    direct_failed = true;
                    if let Some(error) = relay_failed.take() {
                        return Err(error);
                    }
                }
            },
            result = &mut relay, if relay_failed.is_none() => match result {
                Ok((connected, extra)) => return Ok((connected, Some(extra))),
                Err(error) => {
                    if direct_failed {
                        return Err(error);
                    }
                    relay_failed = Some(error);
                }
            },
        }
    }
}

/// Enroll (again) with `mac` on `link`, in the background.
pub(crate) fn enroll_later(link: Link, mac: String) {
    let Some(memory) = memory() else { return };
    tokio::spawn(async move {
        let identity = memory.identity();
        let reply = tokio::time::timeout(ENROLL_TIMEOUT, async {
            let args = serde_json::json!({ "phoneKey": identity.public_b64() });
            let mut channel = link.open(lan::LAN_SERVICE, args).await.ok()?;
            match channel.recv().await? {
                ChannelEvent::Data(bytes) => serde_json::from_slice::<LanEnrollReply>(&bytes).ok(),
                ChannelEvent::Closed(_) => None,
            }
        })
        .await;
        match reply.ok().flatten().as_ref().and_then(LanMac::from_reply) {
            Some(entry) => {
                tracing::info!(addresses = ?entry.addresses, port = entry.port, "LAN direct path enrolled");
                memory.enrolled(&mac, entry);
            }
            None => tracing::debug!("LAN direct path not enrolled on this link"),
        }
    });
}
