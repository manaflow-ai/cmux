# Swift CLI to Rust migration

Goal: native Rust ownership of the entire cmux CLI with observable parity, canonical CodeRouter commands, agent-friendly discovery/output/errors, and measured macOS bundle-size impact. Swift app socket action ownership stays in the app. No Swift executable fallback is a completed migration.

## Shared module contract

Each command module owns `src/commands/<module>.rs` (and optionally its same-named subdirectory). It exports:

```rust
use crate::{Context, CliError, Result};
pub fn run(ctx: &Context, command: &str, args: &[String]) -> Result<Option<i32>>;
```

Return `Ok(None)` only for commands outside your ownership. A handled command returns `Ok(Some(exit_code))`. Exact legacy command behavior, aliases, stdout, stdin, secret handling and process signals are the compatibility baseline. New JSON envelope uses `--output json`; existing `--json` keeps legacy payload shape.

Core API (root owns lib.rs/main.rs/Cargo.toml and dispatch):
- `Context { json: bool, envelope: bool, non_interactive: bool, dry_run: bool, explain: bool, socket: Option<String>, password: Option<String>, window: Option<String>, id_format: String, timeout: std::time::Duration }`
- `ctx.rpc(method: &str, params: serde_json::Value) -> Result<serde_json::Value>`: shared socket transport, lazy connection.
- `ctx.raw(command: &str) -> Result<String>`: legacy socket request.
- `ctx.emit(value: &Value) -> Result<()>`: JSON payload/envelope output.
- `ctx.print(text: impl AsRef<str>) -> Result<()>`: line output, handles broken pipes.
- `ctx.resolve_id(kind: &str, value: Option<&str>) -> Result<Option<String>>`: window/workspace/pane/surface resolution, caller context.
- `CliError::usage(message)`, `CliError::new(code, message)`, `.next(command)`, `.exit(code)`.
- `type Result<T> = std::result::Result<T, CliError>`; IO and serde_json conversions exist.
- `crate::args::take_option(&mut Vec<String>, name) -> Result<Option<String>>`, `take_flag(&mut Vec<String>,name) -> bool`, `reject_remaining(&[String], usage) -> Result<()>`, `parse_bool(&str)->Result<bool>`.

Add module-local unit tests, emphasizing socket method/params and behavioral edge cases. Do not build locally. Root coordinates remote compilation. Do not modify other modules, shared files, Swift code, or Cargo manifest without coordinating. Do not commit until root requests it; selective ownership staging only. Do not substitute generic method-name guessing for actual legacy mappings. Report remaining gaps explicitly.

## Ownership

Root: core, dispatch, integration, final completeness audit, PR.
Assigned agents: transport; topology; terminal; browser; cloud; cloud transfer; hooks; hook state; integrations; sessions/restore; open/diff; config/docs; notifications/feed; simulator; tmux/ssh; CodeRouter; packaging; parity tests.
