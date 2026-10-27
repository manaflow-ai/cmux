use cmux_diff_sidecar::protocol::{DiffEvent, DiffRequest, DiffResponse, DiffTransportConfig};
use ts_rs::{Config, ExportError, TS};

fn main() -> Result<(), ExportError> {
    let config = Config::from_env();
    DiffRequest::export_all(&config)?;
    DiffResponse::export_all(&config)?;
    DiffEvent::export_all(&config)?;
    DiffTransportConfig::export_all(&config)?;
    Ok(())
}
