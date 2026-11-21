//! The acpmux MCP server's name and the env var naming its session (`acpmux_mcp.rs`), read by
//! the code that lists, configures and serves it.

pub const SERVER_NAME: &str = "acpmux";
/// The session the tools act for, set in this server's env with its caller token.
pub const SESSION_ENV: &str = "ACPMUX_SESSION_ID";
