//! Daemon-owned v2 lifecycle state.

use crate::hub::{Hub, HubWriter};
use std::sync::Arc;

/// The single v2 handle a daemon keeps after its listener is ready.
///
/// Construction is intentionally synchronous: starting v2 never gates the
/// daemon's v1 listener or waits on a chat/book.
pub struct V2 {
    pub hub: Arc<Hub>,
    pub writer: Option<HubWriter>,
}

impl V2 {
    pub fn new(hub: Hub, writer: HubWriter) -> Self {
        Self { hub: Arc::new(hub), writer: Some(writer) }
    }

    pub fn hub(&self) -> Arc<Hub> {
        Arc::clone(&self.hub)
    }

    pub fn take_writer(&mut self) -> Option<HubWriter> {
        self.writer.take()
    }
}
