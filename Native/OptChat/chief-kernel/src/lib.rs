//! The Chief kernel's pure core (plans/cmux-next/chief-engines-DESIGN.md,
//! cloud-chief-durable-DESIGN.md section 13): what every Chief engine and
//! placement shares, with no I/O. It builds natively for the Mac and Linux
//! host and for `wasm32-unknown-unknown` inside the Cloud Chief's Durable
//! Object. Synchronous, no threads, no clock, no randomness: time and seeds
//! come in each call's context, and JSON crosses the boundary.

/// The system text of a Chief turn (stub).
pub fn render_system(
    _profile_json: &str,
    _engine: &str,
    _tools_json: &str,
) -> Result<String, String> {
    Err("not yet".into())
}
