# Machines for agent sessions

`cmux agent machine` connects this machine's daemon to the daemons on your other machines, so
`cmux agent ls` shows every session everywhere and `MACHINE/NAME` reaches a session on any of them.
Each `machine` command's `--help` lists every flag and ends with examples. The old spellings still
work: `cmux agent host` (and `hosts`, `peer`), `host place`, `host vm-host` and the `--host` flag.

## Add a machine

| Task | Command |
| --- | --- |
| Add a machine in one go: reach, install, daemon, harness, link | `cmux agent machine enroll mini-4` |
| The same, copying a harness profile to it | `cmux agent machine enroll mini-4 --harness codex` |
| Only install acpmux over ssh and add the machine | `cmux agent machine setup mini-4` |
| Add a machine that already runs a daemon | `cmux agent machine add mini-3` |
| Tailnet machines that could be added | `cmux agent machine candidates` |
| Remove a machine | `cmux agent machine rm mini-3` |

`machine add` returns at once and probes the machine in the background; `cmux agent machine ls` shows the result.

## Check them

| Task | Command |
| --- | --- |
| Your machines and their connection state | `cmux agent machine ls` |
| Every machine's health: reachable, round trip, disk, load, sessions, build | `cmux agent machine status` |
| One machine after a request to it failed | `cmux agent machine status mini-3` |
| Check a machine step by step, changing nothing | `cmux agent machine doctor mini-3` |
| The same, and repair what fails | `cmux agent machine doctor mini-3 --fix` |
| Which machine a new session would go to, and why | `cmux agent machine pick` |
| Which machine a build would go to | `cmux agent machine pick --build` |
| Start a session on the machine `pick` chooses | `cmux agent new --machine auto -m codex "fix the flaky test"` |

## Keep them up to date

| Task | Command |
| --- | --- |
| Push this build to a machine and restart its daemon | `cmux agent machine update mini-3` |
| Update every idle machine, never moving one back | `cmux agent machine update --all --if-idle --keep-newer` |
| Keep updates off a machine for a while | `cmux agent machine hold mini-3 --reason "soak run" --until 2026-10-31T23:59:59Z` |
| Let updates through again | `cmux agent machine hold mini-3 --release` |
| Bring this Linux machine to the newest build | `cmux agent machine self-update` |

## Pair without ssh

| Task | Command |
| --- | --- |
| Mint a pairing ticket on the machine others join | `cmux agent machine ticket new` |
| Join with a pasted ticket, on the other machine | `cmux agent machine join` (reads the ticket from stdin) |
| Tickets and paired machines | `cmux agent machine ticket ls` |
| Unpair a machine and close its connections | `cmux agent machine ticket revoke mini-2` |

## Approvals and consent

| Task | Command |
| --- | --- |
| From a Mac, let its cmux app allow another machine's prompts | `cmux agent machine approvals enroll mini-2` |
| The Macs that may allow prompts here | `cmux agent machine approvals` |
| Turn off a paired machine's Full access | `cmux agent machine ticket full-access mini-2 off` |
| Whether a machine is dedicated: agents run with no per-session sandbox, the VM is the boundary | `cmux agent machine dedicated [NAME] [on\|off]` |
| This machine's load now, one JSON object (cmux Cloud sizes its machines from it) | `cmux agent machine load --json` |
| The shadow admission verdict for host readings given as JSON on stdin; defers nothing (inputs: `cmux-host-budget/testdata/shadow-verdict-v2.json`) | `cmux agent machine verdict --json` |
| Add one muted line to every live chat here | `cmux agent machine notice --text TEXT` |

Every placement (`new --machine auto`, `dispatch --machine auto`, `machine pick`, a sub-session's
host `auto`) and every session create also logs the shadow admission verdict (cmuxterm-hq#7342)
next to its pick: one info line `shadow-admission {JSON}` in the daemon's log (`daemon.log`, or
`journalctl --user -u acpmux.service` under systemd). The JSON has `ts`, `site` (`place`, `pick`, `subsession`, `admit` or `over-cap`), `pick`, the
pick's `would_defer`, `reason`, `inputs_digest`, `formula_version`, and `hosts`. Nothing is
deferred on it. `daemon status --json` lists each host's last verdict as `shadowAdmission`, and
`cmux agent ls` ends with a `HOST: would-defer: REASON` line for each host whose verdict would defer.
Its `host_pressure` carries the readings this machine's verdict uses beside the meter's keys
(`cores`, `pressure`, `available_ram_fraction`, `swap_mb_per_min`): `cpus`, `pressureAgeMs` (the
meter sample's age), `load` (the OS load averages; the verdict reads `load[0]`), `ram.totalBytes`
and `swap.usedBytes`/`swap.totalBytes`, so a reader builds the same inputs placement does.

Screen and control consent, an allow, and turning Full access on are the person's: the daemon takes
them only from the cmux app, never from a shell or an agent.

See also [sessions](cli-sessions.md), [harnesses](cli-harnesses.md) and [the daemon](cli-daemon.md).
