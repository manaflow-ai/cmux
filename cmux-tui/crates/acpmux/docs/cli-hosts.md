# acpmux CLI: machines

`acpmux machine` connects this machine's daemon to the daemons on your other machines, so
`acpmux ls` shows every session everywhere and `MACHINE/NAME` reaches a session on any of them.
Each `machine` command's `--help` lists every flag and ends with examples. The old spellings still
work: `acpmux host` (and `hosts`, `peer`), `host place`, `host vm-host` and the `--host` flag.

## Add a machine

| Task | Command |
| --- | --- |
| Add a machine in one go: reach, install, daemon, harness, link | `acpmux machine enroll mini-4` |
| The same, copying a harness profile to it | `acpmux machine enroll mini-4 --harness codex` |
| Only install acpmux over ssh and add the machine | `acpmux machine setup mini-4` |
| Add a machine that already runs a daemon | `acpmux machine add mini-3` |
| Tailnet machines that could be added | `acpmux machine candidates` |
| Remove a machine | `acpmux machine rm mini-3` |

`machine add` returns at once and probes the machine in the background; `acpmux machine ls` shows the result.

## Check them

| Task | Command |
| --- | --- |
| Your machines and their connection state | `acpmux machine ls` |
| Every machine's health: reachable, round trip, disk, load, sessions, build | `acpmux machine status` |
| One machine after a request to it failed | `acpmux machine status mini-3` |
| Check a machine step by step, changing nothing | `acpmux machine doctor mini-3` |
| The same, and repair what fails | `acpmux machine doctor mini-3 --fix` |
| Which machine a new session would go to, and why | `acpmux machine pick` |
| Which machine a build would go to | `acpmux machine pick --build` |
| Start a session on the machine `pick` chooses | `acpmux new --machine auto -m codex "fix the flaky test"` |

## Keep them up to date

| Task | Command |
| --- | --- |
| Push this build to a machine and restart its daemon | `acpmux machine update mini-3` |
| Update every idle machine, never moving one back | `acpmux machine update --all --if-idle --keep-newer` |
| Keep updates off a machine for a while | `acpmux machine hold mini-3 --reason "soak run" --until 2026-10-31T23:59:59Z` |
| Let updates through again | `acpmux machine hold mini-3 --release` |
| Bring this Linux machine to the newest build | `acpmux machine self-update` |

## Pair without ssh

| Task | Command |
| --- | --- |
| Mint a pairing ticket on the machine others join | `acpmux machine ticket new` |
| Join with a pasted ticket, on the other machine | `acpmux machine join` (reads the ticket from stdin) |
| Tickets and paired machines | `acpmux machine ticket ls` |
| Unpair a machine and close its connections | `acpmux machine ticket revoke mini-2` |

## Approvals and consent

| Task | Command |
| --- | --- |
| From a Mac, let its cmux app allow another machine's prompts | `acpmux machine approvals enroll mini-2` |
| The Macs that may allow prompts here | `acpmux machine approvals` |
| Turn off a paired machine's Full access | `acpmux machine ticket full-access mini-2 off` |
| Whether a machine is dedicated: agents run with no per-session sandbox, the VM is the boundary | `acpmux machine dedicated [NAME] [on\|off]` |
| This machine's load now, one JSON object (cmux Cloud sizes its machines from it) | `acpmux machine load --json` |
| The shadow admission verdict for host readings given as JSON on stdin; defers nothing (inputs: `cmux-host-budget/testdata/shadow-verdict-v2.json`) | `acpmux machine verdict --json` |
| Add one muted line to every live chat here | `acpmux machine notice --text TEXT` |

Every placement (`new --machine auto`, `dispatch --machine auto`, `machine pick`, a sub-session's
host `auto`) and every session create also logs the shadow admission verdict (cmuxterm-hq#7342)
next to its pick: one info line `shadow-admission {JSON}` in the daemon's log (`daemon.log`, or
`journalctl --user -u acpmux.service` under systemd). The JSON has `ts`, `site` (`place`, `pick`, `subsession`, `admit` or `over-cap`), `pick`, the
pick's `would_defer`, `reason`, `inputs_digest`, `formula_version`, and `hosts`. Nothing is
deferred on it. `daemon status --json` lists each host's last verdict as `shadowAdmission`, and
`acpmux ls` ends with a `HOST: would-defer: REASON` line for each host whose verdict would defer.
Its `host_pressure` carries the readings this machine's verdict uses beside the meter's keys
(`cores`, `pressure`, `available_ram_fraction`, `swap_mb_per_min`): `cpus`, `pressureAgeMs` (the
meter sample's age), `load` (the OS load averages; the verdict reads `load[0]`), `ram.totalBytes`
and `swap.usedBytes`/`swap.totalBytes`, so a reader builds the same inputs placement does.

Screen and control consent, an allow, and turning Full access on are the person's: the daemon takes
them only from the cmux app, never from a shell or an agent.

See also [sessions](cli-sessions.md), [harnesses](cli-harnesses.md) and [the daemon](cli-daemon.md).
