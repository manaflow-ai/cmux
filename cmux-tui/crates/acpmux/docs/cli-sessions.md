# acpmux CLI: sessions

Start agents, talk to them, wait on them and read what they said. Every command takes a session by
name, by `HOST/NAME` for one on a peer, or by id. Each command's `--help` lists every flag and ends
with examples; `--json` on any command prints the raw response.

## Start one

| Task | Command |
| --- | --- |
| Start a session and give it a first prompt, without opening the TUI | `cmux agent new -m codex -n fix-27310 -d "Fix the failing test"` |
| Start one in its own worktree on a brief that reports back | `cmux agent new -n fix-27310 --worktree ~/Projects/cmux@origin/main --prompt-file ~/notes/brief.md --report-to coord -d` |
| Start one from inside a session that is not its child (its turns never show there) | `cmux agent new -n scratch --no-parent -d "Look into the flaky test"` |
| Run one prompt and print only the final reply | `acpmux run -m claude "Summarize the open TODOs"` |
| Get a session by name, creating it when missing | `acpmux ensure coord -m claude` |
| Send a brief to the least-loaded allowed machine | `acpmux dispatch ~/notes/brief.md --machine auto` |
| Run one prompt on several harnesses and compare | `acpmux compare -m claude -m codex "Why does this test flake?"` |
| From an authenticated agent session, race implementations in separate worktrees with a reviewer | `acpmux race new -m codex/gpt-6.1-sol -m codex/gpt-6-astra --reviewer claude/opus --reviewer-effort medium "Fix the flaky test"` |

Running the same `new --worktree ... --prompt-file ...` again reuses the session and sends nothing.

Race CLI commands run inside an authenticated acpmux agent session. Omit `--parent` to use
that agent's own chat, or name a descendant it can manage. `--parent CHAT` does not authorize
an ordinary terminal. From an ordinary terminal, use the chat's **menu → Tools → Race models**
control in cmux NEXT instead.

`race new` starts candidates under that local parent chat and returns a race id. The daemon
continues the race after the CLI exits; candidates inherit the parent's permission rules and
sub-session limits. Each candidate works
in its own Git worktree. The reviewer chooses a winner after the candidate turns finish;
that choice does not certify passing tests or authorize a merge.

From the same authenticated agent session, use `acpmux race show RACE` to read the replies,
paths and decision, `race ls` to list races, and `race stats` for wins per model.
`race stop RACE` cancels the race's sessions. Add the same `--parent` to these commands when
the race belongs to a descendant. Losing sessions close after
a successful review; their worktrees remain recoverable under normal retention. A failed
review keeps the candidates available for inspection.

Racing is available by default. To disable new races for a daemon, start it with
`ACPMUX_DISABLE_RACES=1`; existing results remain readable and running races can still be
stopped. Win rates count completed, reviewer-decided races, once per model per race.

## Talk to one

| Task | Command |
| --- | --- |
| Send a message and return at once | `cmux agent send --no-wait coord "PR 27310 is green"` |
| Send and stream the reply until the turn ends | `cmux agent send review-27310 "Is the diff safe to land?"` |
| Send and print only the reply | `cmux agent send review-27310 -q "Is the diff safe to land?"` |
| From an agent session, say what the message asks of the receiver | `cmux agent send coord --class block "Base is red; I cannot push"` |
| Send a file with it | `cmux agent send fix-27310 --attach ~/notes/before.png "The caret jumps after paste"` |
| Check a `--no-wait` delivery | `cmux agent send --status DELIVERY_ID` |
| Every message this daemon still delivers or delivered today | `cmux agent send --status` |
| An agent's send that waits for the reply (it queues and returns by default) | `cmux agent send --wait coord "…"` |
| From an agent session, message several sessions at once | the `send` tool of the `acpmux` MCP server with `messages: [{to, text}, {to, file}]` (or `tag`), not a shell loop of `cmux agent send --no-wait` |
| Retry a failed last turn | `acpmux retry review-27310` |
| Cancel the running turn | `cmux agent session cancel coord` |

An agent's send steers into a running turn by default (the agent reads it at its next tool
boundary); `--no-steer` queues it instead.

## Read and wait

| Task | Command |
| --- | --- |
| Sessions on every host | `cmux agent ls` |
| The same for a script | `cmux agent ls --json` |
| A session's last reply | `cmux agent last review-27310` |
| Its last few turns, one line each | `cmux agent history coord -n 5` |
| Search every authorized session on this host and its peers | `cmux agent search "cache"` |
| Wait for a turn to end, then print the reply | `cmux agent wait review-27310 --timeout 1800 --print` |
| Wait for several sessions | `cmux agent wait review-27310 review-27311 --all` |
| Find the session behind a PR footer's agent link | `cmux agent resolve "https://cmux.com/deeplink/agent?id=aid-3f9c2a"` |
| Permission requests waiting for an answer | `cmux agent pending` |
| Open the TUI on a session | `cmux agent attach coord` |

`wait` exits 0 when a turn ended, 2 when a permission is waiting and 3 on timeout.

## Everything else about one session: `cmux agent session`

| Task | Command |
| --- | --- |
| State, model, policy and pending requests | `cmux agent session info coord` |
| Stop its agent, keeping the session to resume later | `cmux agent session stop review-27310` |
| Stop it only if it is idle and unchanged since you read its `lastSeq` (exit 6 if not) | `cmux agent session stop review-27310 --if-idle --expect-revision 418` |
| Restart its agent on the installed version | `cmux agent session restart coord` |
| Rename it | `cmux agent session rename review review-27310` |
| Stop a session you started from showing its turns in your chat | `cmux agent session detach scratch` |
| Change its model or effort | `cmux agent session set coord effort=low` |
| Fork it to try another approach | `cmux agent session fork coord -n coord-alt` |
| Print a pending agent question | `cmux agent session answer coord` |
| Reject a pending permission request | `cmux agent session deny coord` |
| The prompts waiting on it | `cmux agent session queue list coord` |
| Take other agents' messages out of its queue | `cmux agent session queue clear coord --from-agents` |
| Follow its raw events | `cmux agent session tail coord -f` |
| Find its messages holding every word, newest first (`--role user\|assistant\|tool`, `--since 24h`, `-n`) | `cmux agent session search coord merged sha --role assistant` |
| Label it | `cmux agent session tag review-27310 pr=27310` |
| How many sub-sessions it runs and queues | `cmux agent session limits coord` |
| Export it as a bundle; import the folder it prints elsewhere | `cmux agent session export coord --dest ~/bundles` |

`session stop --if-idle` stops nothing while the session has a turn (one admitted but not started
yet included, or one its harness started itself), a queued prompt, a pending permission, an agent
request, a background subagent or a background process,
and with `--expect-revision REV` nothing once its revision (`lastSeq` in `cmux agent ls --json` and
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
