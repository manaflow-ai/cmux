//! cmux-mobile-fake-backend: the in-process fake backend (cmux_mobile_link::testing) on a
//! chosen address, for link tests between two hosts without Stack
//! credentials. Bearer tokens are `user:<id>`. Never expose it publicly.
//!
//!   cmux-mobile-fake-backend <listen address>
//!
//! `CMUX_FAKE_TURN=1` also runs a local TURN server (`testing::TestTurn`, plain UDP) and
//! names it in `GET /v1/ice`, so a `--relay-only` dial has a TURN carrier.

#[tokio::main]
async fn main() {
    let address = std::env::args().nth(1).unwrap_or_else(|| "127.0.0.1:8787".into());
    let hop_servers = match std::env::var("CMUX_HOP_RELAY_URL") {
        Ok(url) if url.starts_with("hop://") => vec![cmux_mobile_link::api::HopServer {
            kind: Some("hop".into()),
            url: Some(url),
            ticket: std::env::var("CMUX_HOP_RELAY_TICKET").ok(),
        }],
        _ => Vec::new(),
    };
    let turn = match std::env::var("CMUX_FAKE_TURN").as_deref() {
        Ok("1") => Some(cmux_mobile_link::testing::TestTurn::start().await),
        _ => None,
    };
    let ice_servers = turn.iter().map(|turn| turn.udp_only()).collect();
    let options = cmux_mobile_link::testing::FakeOptions { hop_servers, ice_servers, ..Default::default() };
    let server = cmux_mobile_link::testing::FakeSignaling::start_on(&address, options).await;
    eprintln!("cmux-mobile-fake-backend on {}", server.base_url);
    if turn.is_some() {
        eprintln!("cmux-mobile-fake-backend: TURN on");
    }
    let _ = tokio::signal::ctrl_c().await;
    drop(turn);
}
