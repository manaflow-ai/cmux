//! `cmux route list|show|add|edit|remove|restore|test|use` (ROUTES R1): the
//! daemon's `_acpmux/route/*` and `_acpmux/chat/route.set` methods, so the
//! CLI, the app and MCP share one code path (`server/routes.rs`).

use anyhow::{Result, bail};
use clap::Subcommand;
use serde_json::{Map, Value, json};

use crate::rpc::method;

#[derive(Subcommand)]
pub enum RouteCmd {
    /// Every route with its kind and endpoint, and which scopes use it.
    #[command(alias = "ls")]
    List {
        /// Also name the route this session uses.
        #[arg(long)]
        chat: Option<String>,
    },
    /// One route (secrets show as their references only).
    Show { id: String },
    /// Write a new route file into ~/.config/cmux/routes.
    Add {
        id: String,
        /// direct-subscription, direct-api-key, local-coderouter, subrouter,
        /// cliproxyapi, cmux-router, custom-anthropic, custom-openai.
        #[arg(long)]
        kind: String,
        #[arg(long)]
        name: Option<String>,
        /// Harness families it serves (repeat): claude, codex, ...
        #[arg(long = "family")]
        families: Vec<String>,
        #[arg(long)]
        anthropic_base_url: Option<String>,
        #[arg(long)]
        openai_base_url: Option<String>,
        /// subscription, api-key, bearer or none.
        #[arg(long)]
        auth: Option<String>,
        /// keychain:ITEM or env:VAR, never the secret itself.
        #[arg(long)]
        secret: Option<String>,
        /// NAME=VALUE (repeat); a secret-looking value must be a reference.
        #[arg(long = "header")]
        headers: Vec<String>,
        #[arg(long)]
        health_url: Option<String>,
        /// Route ids to offer when this one fails (repeat, in order).
        #[arg(long = "fallback")]
        fallback: Vec<String>,
        #[arg(long)]
        auto_fallback: bool,
        #[arg(long)]
        notes: Option<String>,
        /// Replace an existing route file.
        #[arg(long)]
        force: bool,
    },
    /// Change fields of a route: KEY=VALUE pairs with the RPC's names
    /// (anthropicBaseUrl=…, secret=keychain:…); KEY= removes one.
    Edit {
        id: String,
        #[arg(required = true)]
        set: Vec<String>,
    },
    /// Move a route file to the backups (restore brings it back).
    #[command(alias = "rm")]
    Remove { id: String },
    /// Bring back a removed route by the backup name `remove` printed.
    Restore { backup: String },
    /// One request to the route: ok, auth_needed, unreachable, rate_limited or unknown.
    Test { id: String },
    /// Use a route: for one chat (--chat), a workspace, a harness family,
    /// or everywhere (--default). `none` clears the binding.
    Use {
        id: String,
        #[arg(long, group = "scope")]
        chat: Option<String>,
        /// With --chat: stop the running turn and switch now (default: after it).
        #[arg(long, requires = "chat")]
        now: bool,
        #[arg(long, group = "scope")]
        workspace: Option<String>,
        #[arg(long, group = "scope")]
        family: Option<String>,
        #[arg(long, group = "scope")]
        default: bool,
    },
}

fn kv(pair: &str) -> Result<(String, String)> {
    match pair.split_once('=') {
        Some((k, v)) if !k.is_empty() => Ok((k.to_owned(), v.to_owned())),
        _ => bail!("{pair:?} is not KEY=VALUE"),
    }
}

pub async fn run(cmd: RouteCmd, json_out: bool) -> Result<()> {
    let (m, params) = match cmd {
        RouteCmd::List { chat } => (method::MUX_ROUTE_LIST, json!({"sessionId": chat})),
        RouteCmd::Show { id } => (method::MUX_ROUTE_SHOW, json!({"id": id})),
        RouteCmd::Add {
            id,
            kind,
            name,
            families,
            anthropic_base_url,
            openai_base_url,
            auth,
            secret,
            headers,
            health_url,
            fallback,
            auto_fallback,
            notes,
            force,
        } => {
            let headers: Map<String, Value> = headers
                .iter()
                .map(|h| kv(h).map(|(k, v)| (k, Value::from(v))))
                .collect::<Result<_>>()?;
            (
                method::MUX_ROUTE_ADD,
                json!({"id": id, "kind": kind, "name": name, "families": families,
                       "anthropicBaseUrl": anthropic_base_url, "openaiBaseUrl": openai_base_url,
                       "auth": auth, "secret": secret, "headers": headers, "healthUrl": health_url,
                       "fallback": fallback, "autoFallback": auto_fallback, "notes": notes,
                       "replace": force}),
            )
        }
        RouteCmd::Edit { id, set } => {
            let mut params = Map::new();
            params.insert("id".into(), Value::from(id));
            for pair in &set {
                let (k, v) = kv(pair)?;
                let value = match k.as_str() {
                    _ if v.is_empty() => Value::Null,
                    "families" | "fallback" => {
                        Value::from(v.split(',').map(str::to_owned).collect::<Vec<_>>())
                    }
                    "autoFallback" => Value::from(v == "true"),
                    _ => Value::from(v),
                };
                params.insert(k, value);
            }
            (method::MUX_ROUTE_EDIT, Value::Object(params))
        }
        RouteCmd::Remove { id } => (method::MUX_ROUTE_REMOVE, json!({"id": id})),
        RouteCmd::Restore { backup } => (method::MUX_ROUTE_RESTORE, json!({"backup": backup})),
        RouteCmd::Test { id } => (method::MUX_ROUTE_TEST, json!({"id": id})),
        RouteCmd::Use { id, chat, now, workspace, family, default } => {
            let route = (id != "none").then_some(id);
            match (chat, workspace, family, default) {
                (Some(chat), ..) => (
                    method::MUX_CHAT_ROUTE_SET,
                    json!({"sessionId": chat, "routeId": route,
                           "when": if now { "now" } else { "after-turn" }}),
                ),
                (_, Some(ws), ..) => (
                    method::MUX_ROUTE_DEFAULT_SET,
                    json!({"scope": format!("workspace:{ws}"), "routeId": route}),
                ),
                (_, _, Some(f), _) => (
                    method::MUX_ROUTE_DEFAULT_SET,
                    json!({"scope": format!("family:{f}"), "routeId": route}),
                ),
                (_, _, _, true) => {
                    (method::MUX_ROUTE_DEFAULT_SET, json!({"scope": "global", "routeId": route}))
                }
                _ => bail!("say where: --chat ID, --workspace ID, --family NAME or --default"),
            }
        }
    };
    let client = crate::daemon::connect(true).await?;
    let reply = client.request(m, params).await?;
    if json_out || m != method::MUX_ROUTE_LIST {
        println!("{}", serde_json::to_string_pretty(&reply)?);
        return Ok(());
    }
    for r in reply["routes"].as_array().into_iter().flatten() {
        let url = r["anthropicBaseUrl"].as_str().or(r["openaiBaseUrl"].as_str()).unwrap_or("-");
        println!(
            "{:<20} {:<20} {:<18} {}",
            r["id"].as_str().unwrap_or(""),
            r["name"].as_str().unwrap_or(""),
            r["kind"].as_str().unwrap_or(""),
            url
        );
    }
    for p in reply["problems"].as_array().into_iter().flatten() {
        eprintln!("problem: {}", p.as_str().unwrap_or(""));
    }
    Ok(())
}
