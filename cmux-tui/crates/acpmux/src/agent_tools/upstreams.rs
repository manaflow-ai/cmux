//! The `cmux` server's upstreams: the other servers folded into its [`UPSTREAMS_ENV`] (code
//! mode), acpmux's own servers sharing one process, and the `cmux` server served by the daemon's
//! gateway (`mcp_gateway.rs`) with acpmux's own servers at its tool endpoint.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use cmux_json::JsonSet as _;
use serde_json::{Map, Value, json};

use super::{AgentTools, McpServer, UPSTREAMS_ENV};

/// The upstream spec field that names the process a server runs in when others run in it too
/// (`cmux mcp serve`'s `upstream.rs`): `{command, args, env}`, the same for each of them.
pub const SHARED_FIELD: &str = "shared";

/// The upstream spec field that names the loopback HTTP endpoint a server is served at instead
/// (`cmux mcp serve`'s `upstream_http.rs`): `{url, headers}`, the daemon's gateway
/// (`mcp_gateway.rs`).
pub const HTTP_FIELD: &str = "http";

/// The one launch of acpmux's own servers in `servers` ([`crate::tools_mcp::SERVERS`]):
/// `acpmux tools-mcp` under their prefix with every env value of theirs, all for the same
/// session. None without such a server, or when two of them disagree (another command, prefix
/// or value of a key): then each runs on its own, as before.
fn shared_helper(servers: &[McpServer]) -> Option<Value> {
    let mut launch: Option<(&PathBuf, &[String])> = None;
    let mut env = BTreeMap::<&str, &str>::new();
    for server in servers.iter().filter(|s| crate::tools_mcp::owns(&s.name, &s.args)) {
        let (_, prefix) = server.args.split_last()?;
        match launch {
            None => launch = Some((&server.command, prefix)),
            Some((command, first)) if *command == server.command && first == prefix => {}
            Some(_) => return None,
        }
        for (key, value) in &server.env {
            if env
                .insert(key.as_str(), value.as_str())
                .is_some_and(|before| before != value.as_str())
            {
                return None;
            }
        }
    }
    let (command, prefix) = launch?;
    let mut args = prefix.to_vec();
    args.push(crate::tools_mcp::ARG.to_owned());
    Some(json!({"command": command, "args": args, "env": env}))
}

/// Whether an ACP agent's `agentCapabilities` say it takes HTTP MCP servers.
pub fn takes_http(capabilities: Option<&Value>) -> bool {
    capabilities.and_then(|c| c.pointer("/mcpCapabilities/http")).and_then(Value::as_bool)
        == Some(true)
}

impl AgentTools {
    /// Code mode for every agent tool: the other servers, as `scoped` and
    /// `for_session` left them (the Chief's turns keep none), go into the
    /// `cmux` server's [`UPSTREAMS_ENV`] and leave the list. Without a
    /// `cmux` server (cmux.json turns MCP off) they stay as they are.
    pub fn folded(mut self) -> Self {
        let Some(at) = self.servers.iter().position(|s| s.name == "cmux") else {
            return self;
        };
        let mut cmux = self.servers.remove(at);
        cmux.env.retain(|(k, _)| k != UPSTREAMS_ENV);
        // acpmux's own servers run in one process (`tools_mcp.rs`): each keeps its own spec
        // (a `cmux` that does not read `shared` starts it as before) and names the one launch.
        let shared = shared_helper(&self.servers);
        // Always set, `[]` too: a value a harness passes on from its own env
        // (a preset's) must never name the servers.
        let upstreams: Vec<Value> = self
            .servers
            .iter()
            .map(|s| {
                let env: Map<String, Value> =
                    s.env.iter().map(|(k, v)| (k.clone(), json!(v))).collect();
                let mut spec =
                    json!({"name": s.name, "command": s.command, "args": s.args, "env": env});
                // The secret card waits for the person, not for a timer.
                if s.name == crate::secret_mcp::SERVER_NAME {
                    spec.set("callTimeoutSecs", json!(3600));
                }
                if let Some(shared) = &shared
                    && crate::tools_mcp::owns(&s.name, &s.args)
                {
                    spec.set(SHARED_FIELD, shared.clone());
                }
                spec
            })
            .collect();
        cmux.env.push((UPSTREAMS_ENV.to_owned(), Value::Array(upstreams).to_string()));
        self.servers = vec![cmux];
        self
    }

    /// The `cmux` server (after [`AgentTools::folded`]) reached through the daemon's gateway
    /// (`mcp_gateway.rs`) for session `session_id` in `cwd`: the daemon starts it on the chat's
    /// first request and stops it when the chat is idle, so no tool server runs under the harness.
    /// Unchanged without a gateway (not the daemon, or [`crate::mcp_gateway::OFF_ENV`] is `0`).
    pub fn via_gateway(self, session_id: &str, cwd: &Path) -> Self {
        self.via_gateway_on(crate::mcp_gateway::active().as_deref(), session_id, cwd)
    }

    /// [`AgentTools::via_gateway`] on `gateway`. acpmux's own servers in the `cmux` server's
    /// [`UPSTREAMS_ENV`] each get the gateway's tool endpoint as `http` beside their launch, so
    /// the `cmux` server the gateway starts runs none of them (a `cmux` that does not read `http`
    /// starts them as before).
    pub fn via_gateway_on(
        mut self,
        gateway: Option<&crate::mcp_gateway::Gateway>,
        session_id: &str,
        cwd: &Path,
    ) -> Self {
        let (Some(gateway), Some(at)) =
            (gateway, self.servers.iter().position(|s| s.name == "cmux"))
        else {
            return self;
        };
        let Some(mut cmux) = self.servers.get(at).cloned() else {
            return self;
        };
        let tools = gateway.tools_endpoint(session_id);
        let http = json!({"url": tools.url, "headers": {"Authorization": tools.authorization}});
        for (_, value) in cmux.env.iter_mut().filter(|(k, _)| k == UPSTREAMS_ENV) {
            let Ok(Value::Array(mut specs)) = serde_json::from_str::<Value>(value) else {
                continue;
            };
            for spec in &mut specs {
                let args: Vec<String> = spec
                    .get("args")
                    .and_then(Value::as_array)
                    .map(|a| a.iter().filter_map(Value::as_str).map(str::to_owned).collect())
                    .unwrap_or_default();
                if crate::tools_mcp::owns(
                    spec.get("name").and_then(Value::as_str).unwrap_or_default(),
                    &args,
                ) {
                    spec.set(HTTP_FIELD, http.clone());
                }
            }
            *value = Value::Array(specs).to_string();
        }
        let launch = crate::mcp_gateway::Launch {
            command: cmux.command.clone(),
            args: cmux.args.clone(),
            env: cmux.env.clone(),
            cwd: Some(cwd.to_owned()),
        };
        // Not registered: the harness's own stdio `cmux` server keeps its stdio upstreams.
        if let Some(endpoint) = gateway.register(session_id, launch) {
            if let Some(slot) = self.servers.get_mut(at) {
                *slot = cmux;
            }
            self.http.insert("cmux".to_owned(), endpoint);
        }
        self
    }
}
