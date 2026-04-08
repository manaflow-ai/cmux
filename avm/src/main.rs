#![allow(dead_code)] // Public API surfaces used by tests and future integration.

mod detector;
mod governor;
mod policy;
mod proxy;
mod registry;
mod server;
mod shell;

use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result};
use tokio::sync::Mutex;
use tracing_subscriber::EnvFilter;

use detector::PiiDetector;
use policy::Policy;
use proxy::{EgressLog, ProxyState};
use registry::Registry;
use server::DaemonState;
use shell::{CommandChecker, PendingApprovals};

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .init();

    let policy_path = Policy::default_path();
    let policy = Policy::load(&policy_path).context("loading policy")?;

    tracing::info!(
        cpu_limit = policy.resource_caps.cpu_time_secs,
        rss_limit = policy.resource_caps.rss_bytes,
        pii_patterns = policy.pii_patterns.len(),
        allow_domains = policy.network.allow_domains.len(),
        block_domains = policy.network.block_domains.len(),
        "loaded policy"
    );

    // Create shared proxy state (detector + network policy + egress log).
    let proxy_state = Arc::new(Mutex::new(ProxyState {
        network_policy: policy.network.clone(),
        detector: PiiDetector::new(&policy.pii_patterns),
        log: EgressLog::default(),
    }));

    // Create main daemon state.
    let state = Arc::new(Mutex::new(DaemonState {
        registry: Registry::new(),
        policy: policy.clone(),
        command_checker: CommandChecker::new(),
        pending_approvals: PendingApprovals::new(),
        proxy: Arc::clone(&proxy_state),
        proxy_port: None,
    }));

    // Start the egress proxy.
    let proxy_port = proxy::start_proxy(Arc::clone(&proxy_state)).await?;
    {
        let mut s = state.lock().await;
        s.proxy_port = Some(proxy_port);
    }
    tracing::info!(
        proxy_port,
        "egress proxy started — set HTTP_PROXY=http://127.0.0.1:{proxy_port} for agent shells"
    );

    // Spawn the resource governor (samples every 5 seconds).
    let gov_state = Arc::clone(&state);
    let gov_caps = policy.resource_caps.clone();
    tokio::spawn(async move {
        let mut ticker = tokio::time::interval(Duration::from_secs(5));
        loop {
            ticker.tick().await;
            let mut s = gov_state.lock().await;
            if !s.registry.is_empty() {
                let verdicts = governor::sweep(&mut s.registry, &gov_caps);
                drop(s);
                for v in &verdicts {
                    if let Some(ref reason) = v.reason {
                        tracing::info!(
                            agent_id = v.agent_id,
                            pid = v.pid,
                            reason,
                            "governor verdict"
                        );
                    }
                }
            }
        }
    });

    let socket_path = server::default_socket_path();
    server::serve(&socket_path, state).await
}
