//! cmux Computer Use as one of acpmux's own tool servers ([`crate::tools_mcp::SERVERS`]), so a
//! chat's `cmux-computer-use` runs where theirs run: in the daemon's gateway (`mcp_gateway.rs`,
//! `/mcp/<session>/tools/cmux-computer-use`), or in the one `acpmux tools-mcp` a chat's `cmux`
//! server shares, instead of an `acpmux computer-use-mcp` stdio process under every harness
//! (about 26 MB each; one per chat on every machine, 2026-11-25). Leo, 2026-11-25: "like we need
//! to make sure our optimization of our processes and memory still goes on too... and optimizing
//! tool calls and mcp servers for our app...". The stdio bridge ([`super::mcp`]) stays for
//! everything without a gateway or shared helper (a terminal's agent, an older `cmux`).
//!
//! What the stdio bridge kept per process is kept per session here ([`Bridge`]), because the
//! gateway makes a chat's servers again after an idle stop: the [`Caller`] (its session key,
//! label and workspace), whether its client defers to its own Computer Use (Codex), and the
//! display-awake hold. The session ends on the worker (approvals and cursor dropped) when the
//! chat is forgotten ([`end`], from `mcp_gateway::forget`) or its `tools-mcp` process ends
//! ([`end_all`]), as the stdio bridge ended it when its pipe closed.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock, PoisonError};

use anyhow::{Result, anyhow};
use serde_json::Value;

use super::client::{Caller, DAEMON_SOCKET_ENV, SocketDaemon};
use super::mcp::{LABEL_ENV, SERVER_NAME, SESSION_ENV, WORKSPACE_ENV};

/// One chat's Computer Use state, kept across the gateway's idle stops.
struct Bridge {
    caller: Arc<Caller<SocketDaemon>>,
    /// Its client has its own Computer Use (Codex): ours is the second choice.
    defer: AtomicBool,
    /// Whether the env named the label: then a client's name never replaces it.
    label_named: bool,
    display: Mutex<super::awake::DisplayAwake>,
}

// test-hook-allow: holds no hook; per-session state of the in-process Computer Use server
static BRIDGES: OnceLock<Mutex<HashMap<String, Arc<Bridge>>>> = OnceLock::new();

fn bridges() -> std::sync::MutexGuard<'static, HashMap<String, Arc<Bridge>>> {
    BRIDGES.get_or_init(Default::default).lock().unwrap_or_else(PoisonError::into_inner)
}

fn var(key: &str) -> Option<String> {
    crate::tool_env::var(key).filter(|v| !v.trim().is_empty())
}

/// The chat's bridge, made from the env ([`crate::tool_env`]) the first time.
fn bridge(session: &str) -> Arc<Bridge> {
    bridges()
        .entry(session.to_owned())
        .or_insert_with(|| {
            // The cmux-tui daemon acpmux named for the chat (`agent_tools.rs` `for_session`),
            // else the lookup the stdio bridge makes.
            let daemon = var(DAEMON_SOCKET_ENV)
                .map(|path| SocketDaemon::at(path.into()))
                .unwrap_or_else(SocketDaemon::from_env);
            let named = var(LABEL_ENV);
            let label_named = named.is_some();
            let label = named.unwrap_or_else(|| "An agent".to_owned());
            let caller =
                Caller::new(daemon, session.to_owned(), label).with_workspace(var(WORKSPACE_ENV));
            Arc::new(Bridge {
                caller: Arc::new(caller),
                defer: AtomicBool::new(false),
                label_named,
                display: Mutex::default(),
            })
        })
        .clone()
}

/// `initialize`: the client's name labels the person's approval cards and says whether it has
/// its own Computer Use, as the stdio bridge reads it. A `cmux` server in front (folded `cu_*`
/// tools) names itself and carries its own client's name as `clientInfo.title`; it marks the
/// tools second choice itself, so ours stay unmarked for it.
fn initialize(bridge: &Bridge, params: &Value) -> Option<String> {
    let info = params.get("clientInfo");
    let name = info.and_then(|i| i.get("name")).and_then(Value::as_str).unwrap_or_default();
    let front = name == "cmux";
    let label =
        if front { info.and_then(|i| i.get("title")).and_then(Value::as_str) } else { Some(name) };
    if !bridge.label_named
        && let Some(label) = label.filter(|l| !l.trim().is_empty())
    {
        bridge.caller.set_label(label);
    }
    let defer = !front && super::mcp::defers_to_own_computer_use(params);
    bridge.defer.store(defer, Ordering::Relaxed);
    let instructions =
        if defer { super::mcp::DEFER_INSTRUCTIONS } else { cmux_computer_use::tools::INSTRUCTIONS };
    Some(instructions.to_owned())
}

/// The server for the session in the env ([`SESSION_ENV`]). Its calls need no acpmux daemon
/// connection of the process's: the [`Caller`] reaches the cmux-tui daemon and acpmux itself.
pub(crate) fn served(_daemon: &Arc<crate::tools_mcp::Daemon>) -> Result<crate::tools_mcp::Served> {
    let session = var(SESSION_ENV).ok_or_else(|| anyhow!("{SESSION_ENV} is not set"))?;
    let bridge = bridge(&session);
    let tools = super::mcp::tools_list(false)["tools"].clone();
    let on_init = bridge.clone();
    let on_list = bridge.clone();
    let call = crate::tools_mcp::boxed(move |_session, params: Value| {
        let bridge = bridge.clone();
        async move {
            // Every call keeps the display from dimming into a lock for a while.
            bridge.display.lock().unwrap_or_else(PoisonError::into_inner).touch();
            let caller = bridge.caller.clone();
            // A call may wait on the person's card or a worker restart: off the runtime.
            tokio::task::spawn_blocking(move || super::mcp::call(&caller, &params))
                .await
                .unwrap_or_else(|e| {
                    crate::secret_mcp::error_result(format!("the call stopped: {e}"))
                })
        }
    });
    Ok(crate::tools_mcp::Served {
        name: SERVER_NAME,
        session,
        tools,
        instructions: Some(cmux_computer_use::tools::INSTRUCTIONS.to_owned()),
        call,
        on_initialize: Some(Arc::new(move |params: &Value| initialize(&on_init, params))),
        list: Some(Arc::new(move || {
            super::mcp::tools_list(on_list.defer.load(Ordering::Relaxed))["tools"].clone()
        })),
        handle: None,
    })
}

/// Ends chat `session`'s Computer Use session on the worker (its approvals and cursor go), as
/// the stdio bridge did when its pipe closed. Nothing when it never made a call's bridge.
pub fn end(session: &str) {
    let Some(bridge) = bridges().remove(session) else { return };
    end_bridge(bridge);
}

/// [`end`] for every session this process served (`acpmux tools-mcp` closing).
pub fn end_all() {
    let all: Vec<Arc<Bridge>> = bridges().drain().map(|(_, b)| b).collect();
    for bridge in all {
        end_bridge(bridge);
    }
}

fn end_bridge(bridge: Arc<Bridge>) {
    let caller = bridge.caller.clone();
    match tokio::runtime::Handle::try_current() {
        Ok(handle) => drop(handle.spawn_blocking(move || caller.end_session())),
        Err(_) => caller.end_session(),
    }
}

/// Whether chat `session` has a bridge here (tests).
#[cfg(test)]
pub(crate) fn has(session: &str) -> bool {
    bridges().contains_key(session)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn env(session: &str) -> HashMap<String, String> {
        HashMap::from([
            (SESSION_ENV.to_owned(), session.to_owned()),
            (DAEMON_SOCKET_ENV.to_owned(), "/nonexistent/cmux-tui.sock".to_owned()),
        ])
    }

    #[test]
    fn a_codex_client_gets_the_second_choice_tools_and_a_cmux_front_does_not() {
        let served = crate::tool_env::sync_scope(env("cu-served-codex"), || {
            served(&Arc::default()).unwrap()
        });
        assert_eq!(served.name, SERVER_NAME);
        let list = served.list.as_ref().unwrap();
        let init = served.on_initialize.as_ref().unwrap();
        let first = |tools: Value| tools[0]["description"].as_str().unwrap().to_owned();
        let codex = json!({"clientInfo": {"name": "codex-mcp-client", "version": "1"}});
        assert_eq!(init(&codex).as_deref(), Some(super::super::mcp::DEFER_INSTRUCTIONS));
        assert!(first(list()).starts_with(super::super::mcp::DEFER_PREFIX));
        // A `cmux` server in front marks them itself: ours stay plain, its client's name labels.
        let front = json!({"clientInfo": {"name": "cmux", "title": "codex-mcp-client"}});
        assert_eq!(init(&front).as_deref(), Some(cmux_computer_use::tools::INSTRUCTIONS));
        assert!(!first(list()).starts_with(super::super::mcp::DEFER_PREFIX));
        end("cu-served-codex");
    }

    #[test]
    fn the_session_state_outlives_a_remade_server_and_goes_when_the_chat_ends() {
        let made = || {
            crate::tool_env::sync_scope(env("cu-served-keep"), || served(&Arc::default()).unwrap())
        };
        let first = made();
        (first.on_initialize.as_ref().unwrap())(&json!({"clientInfo": {"name": "codex"}}));
        drop(first);
        // The gateway's idle stop made it again: the client it learned at initialize stays.
        let again = made();
        let tools = (again.list.as_ref().unwrap())();
        assert!(
            tools[0]["description"].as_str().unwrap().starts_with(super::super::mcp::DEFER_PREFIX)
        );
        assert!(has("cu-served-keep"));
        end("cu-served-keep");
        assert!(!has("cu-served-keep"));
    }

    #[test]
    fn no_session_in_the_env_is_no_server() {
        let made = crate::tool_env::sync_scope(HashMap::new(), || served(&Arc::default()));
        // The daemon's own env may name one (a session's terminal); only an empty one refuses.
        if std::env::var_os(SESSION_ENV).is_none() {
            assert!(made.is_err());
        }
    }
}
