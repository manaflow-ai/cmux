//! Where a connection to the daemon came from (`server::Origin`).

/// Where a connection came from. A `Web` connection (the WebSocket
/// listener: peer daemons, remote clients, relays) is remote-origin: remote
/// chains build their settings from scratch, so it never starts or sets a
/// preset that carries harness args or a system prompt, and the session
/// pool never serves it. `LocalApp` is the app's own agent pane, proven by
/// every condition in `local_app.rs`: the pool serves it, it may start any
/// configured preset, and like `Web` it never sets a preset's harness args
/// or system prompt and never reads a token back.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Origin {
    /// The local Unix socket.
    #[default]
    Local,
    /// The WebSocket listener.
    Web,
    /// The app's agent pane over the WebSocket listener (`local_app.rs`).
    LocalApp,
    /// A peer acpmux daemon over the WebSocket listener, proven by this
    /// launch's peer token (`peer_auth.rs`). It has the Web's rights except
    /// the current-mode rule for prompts and permission answers.
    Peer,
}

impl Origin {
    /// Web or Peer: a connection held to the Web's rules.
    pub fn web_class(self) -> bool {
        matches!(self, Origin::Web | Origin::Peer)
    }
}
