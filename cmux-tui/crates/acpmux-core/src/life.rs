//! Daemon-owned v2 lifecycle state.

use crate::hub::{Hub, HubWriter};
use std::collections::HashSet;
use std::sync::Arc;
use std::sync::Mutex;

/// The single v2 handle a daemon keeps after its listener is ready.
///
/// Construction is intentionally synchronous: starting v2 never gates the
/// daemon's v1 listener or waits on a chat/book.
pub struct V2 {
    pub hub: Arc<Hub>,
    pub writer: Mutex<Option<HubWriter>>,
    surfaces: Arc<HashSet<String>>,
}

impl V2 {
    pub fn new(hub: Hub, writer: HubWriter) -> Self {
        Self::with_surfaces(hub, writer, ["list"].into_iter().map(str::to_owned).collect())
    }

    pub fn with_surfaces(hub: Hub, writer: HubWriter, surfaces: HashSet<String>) -> Self {
        Self { hub: Arc::new(hub), writer: Mutex::new(Some(writer)), surfaces: Arc::new(surfaces) }
    }

    pub fn hub(&self) -> Arc<Hub> {
        Arc::clone(&self.hub)
    }

    pub fn take_writer(&self) -> Option<HubWriter> {
        self.writer.lock().ok().and_then(|mut writer| writer.take())
    }

    pub fn allows_surfaces(&self, requested: &[&str]) -> bool {
        !requested.is_empty() && requested.iter().all(|surface| self.surfaces.contains(*surface))
    }
}
