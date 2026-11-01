# acpmux CLI: sessions

Start agents, talk to them, wait on them and read what they said. Every command takes a session by
name, by `HOST/NAME` for one on a peer, or by id. Each command's `--help` lists every flag and ends
with examples; `--json` on any command prints the raw response.

## Start one

| Task | Command |
| --- | --- |
| Start a session and give it a first prompt, without opening the TUI | `acpmux new -m codex -n fix-27310 -d "Fix the failing test"` |
| Start one in its own worktree on a brief that reports back | `acpmux new -n fix-27310 --worktree ~/Projects/cmux@origin/main --prompt-file ~/notes/brief.md --report-to coord -d` |
| Run one prompt and print only the final reply | `acpmux run -m claude "Summarize the open TODOs"` |
| Get a session by name, creating it when missing | `acpmux ensure coord -m claude` |
| Send a brief to the least-loaded allowed machine | `acpmux dispatch ~/notes/brief.md --machine auto` |
| Run one prompt on several harnesses and compare | `acpmux compare -m claude -m codex "Why does this test flake?"` |

Running the same `new --worktree ... --prompt-file ...` again reuses the session and sends nothing.

## Talk to one

| Task | Command |
| --- | --- |
| Send a message and return at once | `acpmux send --no-wait coord "PR 27310 is green"` |
| Send and stream the reply until the turn ends | `acpmux send review-27310 "Is the diff safe to land?"` |
| Send and print only the reply | `acpmux send review-27310 -q "Is the diff safe to land?"` |
| From an agent session, say what the message asks of the receiver | `acpmux send coord --class block "Base is red; I cannot push"` |
| Send a file with it | `acpmux send fix-27310 --attach ~/notes/before.png "The caret jumps after paste"` |
| Check a `--no-wait` delivery | `acpmux send --status DELIVERY_ID` |
| From an agent session, message several sessions at once | the `send` tool of the `acpmux` MCP server with `messages: [{to, text}, {to, file}]` (or `tag`), not a shell loop of `acpmux send --no-wait` |
| Retry a failed last turn | `acpmux retry review-27310` |
| Cancel the running turn | `acpmux session cancel coord` |

An agent's send steers into a running turn by default (the agent reads it at its next tool
boundary); `--no-steer` queues it instead.

## Read and wait

| Task | Command |
| --- | --- |
| Sessions on every host | `acpmux ls` |
| The same for a script | `acpmux ls --json` |
| A session's last reply | `acpmux last review-27310` |
| Its last few turns, one line each | `acpmux history coord -n 5` |
| Wait for a turn to end, then print the reply | `acpmux wait review-27310 --timeout 1800 --print` |
| Wait for several sessions | `acpmux wait review-27310 review-27311 --all` |
| Find the session behind a PR footer's agent link | `acpmux resolve "https://cmux.com/deeplink/agent?id=aid-3f9c2a"` |
| Permission requests waiting for an answer | `acpmux pending` |
| Open the TUI on a session | `acpmux attach coord` |

`wait` exits 0 when a turn ended, 2 when a permission is waiting and 3 on timeout.

## Everything else about one session: `acpmux session`

| Task | Command |
| --- | --- |
| State, model, policy and pending requests | `acpmux session info coord` |
| Stop its agent, keeping the session to resume later | `acpmux session stop review-27310` |
| Stop it only if it is idle and unchanged since you read its `lastSeq` (exit 6 if not) | `acpmux session stop review-27310 --if-idle --expect-revision 418` |
| Restart its agent on the installed version | `acpmux session restart coord` |
| Rename it | `acpmux session rename review review-27310` |
| Change its model or effort | `acpmux session set coord effort=low` |
| Fork it to try another approach | `acpmux session fork coord -n coord-alt` |
| Print a pending agent question | `acpmux session answer coord` |
| Reject a pending permission request | `acpmux session deny coord` |
| The prompts waiting on it | `acpmux session queue list coord` |
| Take other agents' messages out of its queue | `acpmux session queue clear coord --from-agents` |
| Follow its raw events | `acpmux session tail coord -f` |
| Label it | `acpmux session tag review-27310 pr=27310` |
| How many sub-sessions it runs and queues | `acpmux session limits coord` |
| Export it as a bundle; import the folder it prints elsewhere | `acpmux session export coord --dest ~/bundles` |

`session stop --if-idle` stops nothing while the session has a turn (one admitted but not started
yet included, or one its harness started itself), a queued prompt, a pending permission, an agent
request, a background subagent or a background process,
and with `--expect-revision REV` nothing once its revision (`lastSeq` in `acpmux ls --json` and
`session info --json`, each record's `seq` in `session tail`) is no longer REV. The check and the
stop happen under the lock that admits turns, so no turn starts in between. A refusal exits 6; with
`--json` its `error.detail` is `busy` (`error.data.busyWith` says what: `turn`, `queued`,
`permission`, `tool_call`, `subagent`, `process` (a background shell of its harness), `unstored` (a
Claude conversation that was never stored), `unadopted_host` (an agent host this daemon could not
adopt, or host records it cannot read), `starting`, `moving`) or `revision_moved`, and
`error.data.revision` is the current revision. It runs on the daemon that owns the session: it is
refused with `--mesh` and for a peer's session (`stop_if_idle_remote`), and by a daemon that predates
it (`stop_if_idle_unsupported`, exit 1).

An allow, and an answer to an agent's question, are accepted only from the cmux app; from the CLI,
`session deny` rejects a request and `session answer` prints the questions. A session's limits are
changed by the cmux app or by a session above it in its family.
See also [hosts](cli-hosts.md), [harnesses](cli-harnesses.md), [the daemon](cli-daemon.md) and
[tasks and other work](cli-work.md).
