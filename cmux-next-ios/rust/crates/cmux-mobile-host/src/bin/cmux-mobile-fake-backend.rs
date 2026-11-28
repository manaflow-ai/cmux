//! cmux-mobile-fake-backend: the in-process fake backend (cmux_mobile_link::testing) on a
//! chosen address, for link tests between two hosts without Stack
//! credentials. Bearer tokens are `user:<id>`. Never expose it publicly.
//!
//!   cmux-mobile-fake-backend <listen address>

#[tokio::main]
async fn main() {
    let address = std::env::args().nth(1).unwrap_or_else(|| "127.0.0.1:8787".into());
    let server = cmux_mobile_link::testing::FakeSignaling::start_on(&address, Default::default()).await;
    eprintln!("cmux-mobile-fake-backend on {}", server.base_url);
    let _ = tokio::signal::ctrl_c().await;
}
