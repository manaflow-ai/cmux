# acpmux CLI: hosts

`acpmux host` connects this machine's daemon to the daemons on your other machines (peers), so
`acpmux ls` shows every session everywhere and `HOST/NAME` reaches a session on any of them.
Each `host` command's `--help` lists every flag and ends with examples.

## Add a machine

| Task | Command |
| --- | --- |
| Add a machine in one go: reach, install, daemon, harness, peer | `acpmux host enroll mini-4` |
| The same, copying a harness profile to it | `acpmux host enroll mini-4 --harness codex` |
| Only install acpmux over ssh and add it as a peer | `acpmux host setup mini-4` |
| Add a peer that already runs a daemon | `acpmux host add mini-3` |
| Tailnet machines that could be added | `acpmux host candidates` |
| Remove a peer | `acpmux host rm mini-3` |

`host add` returns at once and probes the peer in the background; `acpmux host ls` shows the result.

## Check them

| Task | Command |
| --- | --- |
| Peers and their connection state | `acpmux host ls` |
| Every peer's health: reachable, round trip, disk, load, sessions, build | `acpmux host status` |
| One peer after a request to it failed | `acpmux host status mini-3` |
| Check a peer step by step, changing nothing | `acpmux host doctor mini-3` |
| The same, and repair what fails | `acpmux host doctor mini-3 --fix` |
| Where a new session should go, and why | `acpmux host place` |
| Where a build should go | `acpmux host place --build` |

## Keep them up to date

| Task | Command |
| --- | --- |
| Push this build to a peer and restart its daemon | `acpmux host update mini-3` |
| Update every idle peer, never moving one back | `acpmux host update --all --if-idle --keep-newer` |
| Keep updates off a machine for a while | `acpmux host hold mini-3 --reason "soak run" --until 2026-10-31T23:59:59Z` |
| Let updates through again | `acpmux host hold mini-3 --release` |
| Bring this Linux host to the newest build | `acpmux host self-update` |

## Pair without ssh

| Task | Command |
| --- | --- |
| Mint a pairing ticket on the machine others join | `acpmux host ticket new` |
| Join with a pasted ticket, on the other machine | `acpmux host join` (reads the ticket from stdin) |
| Tickets and paired machines | `acpmux host ticket ls` |
| Unpair a machine and close its connections | `acpmux host ticket revoke mini-2` |

## Approvals and consent

| Task | Command |
| --- | --- |
| From a Mac, let its cmux app allow a peer's prompts | `acpmux host approvals enroll mini-2` |
| The Macs that may allow prompts here | `acpmux host approvals` |
| Turn off a paired machine's Full access | `acpmux host ticket full-access mini-2 off` |

Screen and control consent, an allow, and turning Full access on are the person's: the daemon takes
them only from the cmux app, never from a shell or an agent.

See also [sessions](cli-sessions.md), [harnesses](cli-harnesses.md) and [the daemon](cli-daemon.md).
