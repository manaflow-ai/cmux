//! `chiefs` create_channel on this Mac (plans/cmux-next/chief-channels-DESIGN.md).
//!
//! A channel is a cloud group with its own scoped Chief, made by the
//! account's Worker (`channel.create`). This Mac's daemon holds no cloud
//! session; the app does. So this Mac's Chief makes a channel through the
//! app's `home.createChannel` action on the control socket
//! (`CMUX_SOCKET_PATH`): the one path New Channel, `cmux chat channel create`
//! and MCP take, which also turns the new Chief's brain on and invites the
//! people as the person. The caller's `chiefs` grant is checked first
//! (`ChiefTools::chiefs_call`).

use std::sync::Arc;

use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};

use crate::cloud_workspace::{AppActions, ControlSocketActions, RunError};

/// The fields create_channel takes besides `action`.
const FIELDS: [&str; 3] = ["title", "display_name", "people"];

/// Makes channels through the app's `home.createChannel`.
pub struct ChannelMaker {
    app: Arc<dyn AppActions>,
}

impl std::fmt::Debug for ChannelMaker {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("ChannelMaker")
    }
}

impl ChannelMaker {
    pub fn new(app: Arc<dyn AppActions>) -> ChannelMaker {
        ChannelMaker { app }
    }

    /// The app's control socket; None when this host runs outside the app.
    pub fn from_env(env: &dyn Fn(&str) -> Option<String>) -> Option<ChannelMaker> {
        let socket = env("CMUX_SOCKET_PATH").filter(|s| !s.is_empty())?;
        Some(ChannelMaker::new(Arc::new(ControlSocketActions {
            socket: socket.into(),
        })))
    }

    /// Makes the channel `args` asks for. `seed` is this host's turn key: the
    /// same call resent while this host lives keeps one idempotency key, so
    /// a retry after no answer gives the same channel, never a second one.
    pub fn create(&self, args: &Map<String, Value>, seed: &str) -> Result<String, String> {
        if let Some(unknown) = args
            .keys()
            .find(|k| k.as_str() != "action" && !FIELDS.contains(&k.as_str()))
        {
            return Err(format!("chiefs: no field {unknown} for create_channel"));
        }
        let text = |k: &str| {
            args.get(k)
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty())
        };
        let title = text("title").ok_or("chiefs: create_channel needs title")?;
        let people: Vec<&str> = match args.get("people") {
            None => Vec::new(),
            Some(Value::Array(list)) => list
                .iter()
                .map(|p| p.as_str().map(str::trim).filter(|p| !p.is_empty()))
                .collect::<Option<Vec<_>>>()
                .ok_or("chiefs: people are emails or names")?,
            Some(_) => return Err("chiefs: people is a list".to_owned()),
        };
        let mut run = json!({"title": title, "members": people.join(", ")});
        if let Some(name) = text("display_name") {
            run["chief"] = json!(name);
        }
        let mut hash = Sha256::new();
        hash.update(seed.as_bytes());
        hash.update([0]);
        hash.update(run.to_string().as_bytes());
        let digest = hash.finalize();
        let key = format!(
            "chief-channel-{}",
            digest[..12]
                .iter()
                .map(|b| format!("{b:02x}"))
                .collect::<String>()
        );
        let made = self
            .app
            .run("home.createChannel", None, run, Some(&key))
            .map_err(|e| match e {
                RunError::Refused(e) => format!("chiefs: the app refused the channel: {e}"),
                RunError::NoAnswer(e) => format!(
                    "chiefs: the app did not answer ({e}); the channel may still be made, so \
check Home before you try again"
                ),
            })?;
        Ok(format!(
            "{}\nThe channel and its own Chief are made, and its brain is on. Tell the person the \
channel's name and, for each invited person, whether the invite went out.",
            serde_json::to_string_pretty(&made).unwrap_or_default()
        ))
    }
}

/// The answer when this host has no app to make channels with.
pub const NO_APP: &str =
    "chiefs: create_channel needs the cmux app (this Chief runs without its control socket)";
