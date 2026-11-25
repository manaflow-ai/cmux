//! Agent session links: the reader lives in `cmux-web-route` (`agent_link`), shared with the web
//! client's routes (cmuxterm-hq docs/rfd/0083-cmux-web-client.md, Deeplinks).
pub use cmux_web_route::agent_link::*;

#[cfg(test)]
#[path = "agent_link_tests.rs"]
mod tests;
