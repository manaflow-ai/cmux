use cmux_diff_sidecar::protocol::{DiffEvent, DiffRequest, DiffResponse, DiffTransportConfig};
use ts_rs::{Config, TS};

fn main() {
    let config = Config::from_env();
    DiffRequest::export_all(&config).expect("export DiffRequest");
    DiffResponse::export_all(&config).expect("export DiffResponse");
    DiffEvent::export_all(&config).expect("export DiffEvent");
    DiffTransportConfig::export_all(&config).expect("export DiffTransportConfig");
}
