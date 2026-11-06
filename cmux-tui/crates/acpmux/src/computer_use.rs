//! cmux Computer Use for agents: the MCP bridge every session gets
//! ([`mcp`], `acpmux computer-use-mcp`) and the one worker client the bridge,
//! the `cmux computer-use` CLI and the remote relay share ([`client`]).
//! The tool catalog, policy and engine live in `cmux-computer-use`; the
//! worker runs under the cmux Remote host, never in this process.

pub mod client;
pub mod mcp;

/// The tool catalog (names, schemas, the server name and its instructions),
/// for the `cmux` server that folds this one (`cmux mcp serve`).
pub use cmux_computer_use::tools;
