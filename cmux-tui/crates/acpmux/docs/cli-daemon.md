# Manage the agent daemon

One daemon per machine keeps every session alive. Most other commands talk to it and start it when
it is not running. Each `daemon` command's `--help` lists every flag and ends with examples.

| Task | Command |
| --- | --- |
| Status, hosts and the web URL | `cmux agent daemon status` |
| Its busiest callers (client, pid, session) and methods over a recent window | `cmux agent daemon stats --since 5m` |
| What a person feels, as p50/p90/p99 (a prompt's send to ack, a typed key's echo), last minute and since start | `cmux agent daemon felt` |
| Start it unless one runs, and wait until it accepts clients | `cmux agent daemon start` |
| Restart it; hosted sessions resume after | `cmux agent daemon restart` |
| Stop it; hosted agents keep running for the next daemon | `cmux agent daemon shutdown` |
| Stop it and end every agent process | `cmux agent daemon shutdown --end-agents` |
| Run it in the foreground | `cmux agent daemon run` |
| Print the config path and contents | `cmux agent daemon config` |
| Change one config key | `cmux agent daemon config --set session.memory_mb=8192` |
| Permission mode new chats start in (`yolo` = full access, `standard`, `ask`, `default`) | `cmux agent daemon config --set permissions.default=yolo` |
| The same for one harness (wins over the default) | `cmux agent daemon config --set permissions.codex=ask` |
| Reload the catalog config without stopping sessions | `cmux agent daemon reload` |
| See what a log compaction pass would remove | `cmux agent daemon retention --dry-run` |
| Configured harnesses with their defaults | `cmux agent daemon harnesses` |
| The model ids each harness offers | `cmux agent daemon models` |
| The RPC schema as JSON | `cmux agent daemon schema` |
| Open the web dashboard | `cmux agent web` |
| Protocol capability ids this build serves (no daemon needed) | `cmux agent capabilities` |

`config --set` checks the whole resulting config the way a daemon start does and refuses a
value the daemon would refuse, leaving `config.json` as it was. For example,
`transport.wireguard=true` is refused until `transport.wireguardStatic` is in `config.json`.
`daemon reload` keeps the running config when the file fails the same check, and `daemon status`
names the reason when no daemon runs.

The hub carrier (`cmux remote exec|cp|connect --via-machine`) needs no WireGuard setting. A
joined machine (`cmux agent machine join`) runs it on its node key unless the cmux link holds that
key.

`ACPMUX_SOCKET` takes precedence over `ACPMUX_HOME`. To look at an isolated home from a shell that
may be inside another agent: `env -u ACPMUX_SOCKET ACPMUX_HOME=/tmp/example cmux agent daemon status`.

See also [sessions](cli-sessions.md) and [hosts](cli-hosts.md).
