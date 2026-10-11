//! A live compactor call against the real Messages API (the team subrouter
//! unless OPTCHAT_ANTHROPIC_BASE_URL says otherwise). Ignored by default: it
//! spends real tokens. `cargo test --release --test live -- --ignored --nocapture`.

use std::sync::Arc;
use std::time::Duration;

use optchat_host::{Config, Kind, OptChat};

#[test]
#[ignore = "spends real tokens; run with --ignored on a host that reaches the subrouter"]
fn the_compactor_builds_a_long_message_through_the_real_api() {
    let dir = tempfile::tempdir().unwrap();
    let config = Config {
        reporter: Arc::new(|r| println!("report: {r}")),
        ..Config::default()
    };
    println!("compactor {} at {}", config.model, config.base_url);
    let chat = OptChat::open(dir.path(), config).unwrap();
    let long = (0..120)
        .map(|i| format!("Step {i}: the deploy script copies build/{i}.tar to /srv/releases and restarts unit app-{i}."))
        .collect::<Vec<_>>()
        .join("\n");
    chat.append(Kind::Echo, &long).unwrap();
    assert!(
        chat.settle(None, Some(Duration::from_secs(300))),
        "not built: {:?}",
        chat.status().failures
    );
    let view = chat.render_view().text;
    println!("{view}");
    assert!(!view.contains("not summarized yet"), "{view}");
}
