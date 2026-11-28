use std::path::Path;
use std::sync::Arc;

use cmux_mobile_host::browser::BrowserConfig;
use cmux_mobile_host::config::{AcpmuxTarget, ServiceConfig};
use cmux_mobile_host::services::{self, Peer};
use cmux_mobile_host::surface::SurfaceConfig;
use cmux_mobile_link::IncomingChannel;

pub(super) fn config() -> ServiceConfig {
    ServiceConfig {
        tui_socket_dir: Default::default(),
        default_session: "test".into(),
        default_socket: None,
        file_roots: vec![Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/wire_lockstep")],
        acpmux: AcpmuxTarget::Home(Default::default()),
        pairing: None,
        agent_tab_host: None,
        uploads_dir: Default::default(),
        chief_socket: None,
        browser: BrowserConfig::new(None, 0),
        surface: SurfaceConfig::new(None, 0),
        viewport_sync: None,
    }
}

// Serve a single read-only fixture directory, with pairing disabled for this loopback.
pub(super) async fn serve(incoming: IncomingChannel) {
    let peer = Peer {
        device_id: "phone".into(),
        session_id: "test".into(),
        video: None,
        session_exposure: None,
        route: None,
        path: None,
        viewport: None,
    };
    services::serve(Arc::new(config()), peer, Default::default(), incoming).await;
}
