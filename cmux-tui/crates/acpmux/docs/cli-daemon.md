# acpmux CLI: the daemon

One daemon per machine keeps every session alive. Most other commands talk to it and start it when
it is not running. Each `daemon` command's `--help` lists every flag and ends with examples.

| Task | Command |
| --- | --- |
| Status, hosts and the web URL | `acpmux daemon status` |
| Start it unless one runs, and wait until it accepts clients | `acpmux daemon start` |
| Restart it; hosted sessions resume after | `acpmux daemon restart` |
| Stop it; hosted agents keep running for the next daemon | `acpmux daemon shutdown` |
| Stop it and end every agent process | `acpmux daemon shutdown --end-agents` |
| Run it in the foreground | `acpmux daemon run` |
| Print the config path and contents | `acpmux daemon config` |
| Change one config key | `acpmux daemon config --set session.memory_mb=8192` |
| Reload the catalog config without stopping sessions | `acpmux daemon reload` |
| See what a log compaction pass would remove | `acpmux daemon retention --dry-run` |
| Configured harnesses with their defaults | `acpmux daemon harnesses` |
| The model ids each harness offers | `acpmux daemon models` |
| The RPC schema as JSON | `acpmux daemon schema` |
| Open the web dashboard | `acpmux web` |
| Protocol capability ids this build serves (no daemon needed) | `acpmux capabilities` |
| Serve the local CodeRouter | `acpmux router serve` |

`ACPMUX_SOCKET` takes precedence over `ACPMUX_HOME`. To look at an isolated home from a shell that
may be inside another agent: `env -u ACPMUX_SOCKET ACPMUX_HOME=/tmp/example acpmux daemon status`.

See also [sessions](cli-sessions.md) and [hosts](cli-hosts.md).
