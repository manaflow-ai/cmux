# A Chief on a shared Linux box

One Chief that a team shares, on a Linux machine nobody carries around: a fleet VM, a cmux
Cloud machine, any systemd host. It is the always-on brain (`../../README.md`, "Always-on
brain") with the parts a shared box needs: its own system user, hardened units, and one
CPU and memory cap over the Chief and every agent it starts. Design: cmuxterm-hq
`plans/multiplayer-chief/DESIGN.md` (sections 3, 5, 11).

The Chief's conversation lives in cmux's cloud, so teammates reach it from their own apps:
the owner shares the Chief's chat with them (cmux#25631, Conversation Info > Add People, or
`cmux home add-members --conversation <chief conversation> --people "Ben"`). The box needs no
open port for that; nothing listens beyond its own Unix sockets.

Depends on cmux#33003 (the rights table and the audit log, `optchat-chief rights` and
`optchat-chief audit`): `install.sh` refuses an optchat-chief built without them.

## Install (root, once)

Binaries: `optchat-chief`, `cmux-tui` and `acpmux` from one Linux build (and the Rust `cmux`
CLI if you have it; otherwise `cmux-tui` serves as `cmux`). Claude Code or Codex must be
installed for the Chief's user after the user exists (`runuser -u chief -- env HOME=/srv/chief/home
bash -lc 'curl -fsSL https://claude.ai/install.sh | bash'`).

```
./install.sh --optchat-chief ./optchat-chief --cmux-tui ./cmux-tui --acpmux ./acpmux \
  --owner user_<owner account id> [--prefix /srv/chief] [--cpu-quota 400%] [--memory-max 16G]
```

It makes:

| What | Where |
| --- | --- |
| Root-owned binaries (the Chief can run, never replace them) | `/srv/chief/bin` (root:root 0755) |
| System user `chief` and everything it writes | `/srv/chief/home` (its HOME: `.local`, `.claude`), `/srv/chief/ws` (the agents' shared work dir), `/srv/chief/brain` (the Chief's state) |
| Slice with the caps (`CPUQuota`, `MemoryMax`, `TasksMax`) | `/etc/systemd/system/chief-box.slice` |
| Units `chief-box-daemon`, `chief-box-acpmux`, `chief-box-host` | `/etc/systemd/system/` (User=chief, `ProtectSystem=strict`, `ReadWritePaths=/srv/chief`, no capabilities; one private /tmp the three share, owned by the daemon unit, which the others join and stop and restart with; `TMPDIR=/srv/chief/brain/tmp`). install.sh writes each unit to a temp file and renames it, and refuses a unit path that is a symlink (a masked unit) |
| Settings (owner, paths; no secret) | `/srv/chief/chief-box.env` (root, 0644) |
| The model login (root 0600, read by systemd, never in a unit) | `/srv/chief/model.env` |
| The owner's command | `/usr/local/bin/chief-box` |

Run it again to upgrade the binaries or change a cap; it keeps the memory, the pairing,
`rights.json`, the audit log and `model.env`. The host unit does not start until the box is
paired (below). Root never writes inside the Chief's own directories and refuses a prefix,
or any path it writes, that runs through a symlink (so pick a real directory, not one under a
symlinked `/srv`).

## Sign in as the owner

The box pairs like a cmux server, so no session token ever reaches it:

```
chief-box pair --api-base https://<api origin>   # prints a code and four check words
```

In the cmux app, Server > Add Server… takes the code, shows the same words, and approves it.
Place the Chief on that server, then `chief-box start`. `chief-box status` shows the pairing
and the units.

## The model login, and who may prompt

Teammates' prompts run on the owner's model login. Pick one:

- A key billed to the owner or the org: put `ANTHROPIC_API_KEY=...` (or the Bedrock or Vertex
  variables) in `/srv/chief/model.env`, then `chief-box reload-model` and
  `chief-box rights auth api-key` (or `bedrock`,
  `vertex`, `team`, `enterprise`).
- The team's model router: `install.sh ... --claude-base-url URL` (acpmux signs in by URL).

On a personal subscription (`auth personal`, or a login the host cannot tell) a teammate's
message is a suggestion: the Chief runs no turn for it and the owner may send it as their
own. Anthropic's Consumer Terms forbid making an account available to anyone else.

The rights table is `/srv/chief/brain/mux/optchat/rights.json` (0600). The owner edits it
with `chief-box rights` (or the same commands in the chat):

```
chief-box rights                                   # show the table
chief-box rights grant user_ben Read 'Bash(git status*)'
chief-box rights approver user_ana on              # Ana's word counts as the owner's
chief-box rights cap user_ben 2                    # USD per day for Ben's turns
chief-box rights chief-cap 20                      # USD per day for the whole Chief
chief-box rights check user_ben Bash '{"command":"git status"}'
```

A person with no entry gets nothing beyond the default floor: a turn that carries their
text refuses every local effect.

## Audit

Every tool call, admission and turn cost is appended to
`/srv/chief/brain/mux/optchat/audit/audit.jsonl`, hash-chained. The owner reads it with
`/audit` in the chat, or on the box:

```
chief-box audit --last 50 [--who user_ben]
chief-box audit verify     # checks the chain
chief-box audit head       # the last hash, to note elsewhere
```

## Operating

`chief-box logs [N]` (journal of the three units), `chief-box stop` (stops the host and acpmux, so no agent keeps running or spending). The caps cover the
whole slice, so a runaway agent hits `MemoryMax` or `CPUQuota` before the box's other work
does. Disk is not capped by systemd: give `/srv/chief` its own volume or filesystem quota
when the box is shared with other stacks.

Moving the Chief to another box: stop both hosts, then
`optchat-chief memory export --mux-home OLD --out chief-memory.tar --seal` and
`memory import` on the new box (`../../README.md`, "Memory move"), and pair the new box.

Test: `bash deploy/linux-box/tests/install.test.sh` (no root, no systemd needed).
