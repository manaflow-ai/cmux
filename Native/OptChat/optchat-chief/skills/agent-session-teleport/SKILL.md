---
name: agent-session-teleport
description: Move ("teleport") a coding agent's chat - Claude Code, Codex, OpenCode, pi, Gemini or any acpmux harness - to another machine and resume it there with its history, queue and draft. Use when the user says "move that Codex session to cmux-mini-7", "teleport this chat to the cloud", "bring it back to my laptop", or asks to free this Mac by moving idle chats. Covers the agent's own transcript, the folder and branch, the agent's sign-in on the target, and the check that it resumed.
cmux-managed: true
---

# Teleport an agent chat

A chat is an acpmux session. Moving it hands the whole chat (acpmux's own
history, queued prompts, draft) and the agent's own store to the target
machine's daemon, then closes it here: the source never runs it again, so
there is one writer. `acpmux resolve` and agent links follow it to its new
place. This is for agent chats; moving the Chief itself is the
`chief-teleport` skill (the `move` tool).

## What moves, per agent

| Agent | Its own store | Resumes on the target |
|---|---|---|
| Claude Code (any profile: claude, claude-acp, claude-sr...) | `~/.claude/projects/<cwd>/<id>.jsonl`, refiled under the target folder | exactly, with full context |
| Codex (codex, codex-acp, codex-app-server) | `~/.codex/sessions/.../rollout-*-<id>.jsonl` | exactly |
| pi | `~/.pi/agent/sessions/--<cwd>--/<ts>_<id>.jsonl`, refiled under the target folder | exactly |
| OpenCode | its SQLite store: moved as `opencode export`, `opencode import`ed in the target folder | exactly, when `opencode` is installed there |
| Gemini, Cursor, Grok, Kimi, others | not carried | from acpmux's history: the chat and its transcript show, the agent starts a new session |

Not carried: Claude's per-session side folders (subagent transcripts,
large tool results), a `CODEX_HOME` or `CLAUDE_CONFIG_DIR` other than the
default. Say so when the chat used them.

## The folder

- A git checkout on a branch: the branch is pushed (never forced) and checked
  out as a fresh worktree on the target. Uncommitted changes refuse the move:
  commit them first, or pass `--leave-dirty` and say they stayed behind.
- Any other folder under the home: the same path under the target's home,
  made there; its files do not move.
- `--cwd PATH`: run there as the target has it.

## Moving to a machine you added (Mac mini, Linux box, laptop)

```bash
acpmux machine ls                                # targets: connected, current build
acpmux session move CHAT --machine NAME --dry-run   # where it would go; changes nothing
acpmux session move CHAT --machine NAME --json      # the move
```

- `--machine auto` lets placement pick (never a machine a person works at).
- A running turn refuses the move. Wait for it (`acpmux wait CHAT`), or pass
  `--interrupt`: the stopped turn's continuation is queued and runs on the
  target.
- `--all-idle --machine auto` moves every chat here that is between turns.
- A machine named by the user that is not in `acpmux machine ls`: add it
  with `acpmux machine add` (ssh over the tailnet) or `acpmux machine doctor
  NAME --fix`; do not copy files by hand.

A chat that is on another machine moves from here too, with `--from`: this
machine drives both ends over ssh, so a Mac mini and a cloud VM that cannot
reach each other (or this laptop) still trade chats. `--machine local`
brings one back here:

```bash
acpmux session move CHAT --from mini-3 --machine cloud-vm   # mini -> cloud VM
acpmux session move CHAT --from cloud-vm --machine local    # back to this Mac
```

CHAT is the chat's name or id on that machine (`acpmux ls` shows
`HOST/NAME`; give the part after the slash).

## Moving to cmux Cloud

Use the app's Move to Cloud, never a hand-made ssh route:

```bash
cmux cloud list-machines --json
cmux cloud move --machine machine:MACHINE_ID --path DIR
```

It reuses a Cloud machine (the named one, else a connected one, else any,
else a new one), syncs the folder (`cmux link seed push`), moves the chat
through the guarded receive, and shows it as a Cloud workspace. Bring Back
Local returns it. A new machine costs money: ask first unless the user
already said to.

An agent runs it only for its own chat, and then the chat shows the user a
card (Move, Not now, Always): the move waits for their click. For another
chat, tell the user to use Move to Cloud on that chat (its tab's right-click
menu or the command palette), or, when the Cloud machine is one of
`acpmux machine ls`, use `acpmux session move` to it as above.
Never use a team machine someone else made (`fs-lane-*`, another person's
title) unless the user names it.

## Sign-in on the target

The target runs the agent with its own sign-in. Never copy `~/.claude`
credentials, `~/.codex/auth.json`, OpenCode's or pi's `auth.json`, an API key
or a keychain item to another machine, and never print one.

1. Before the move, check the target can run the agent: a short throwaway
   chat there (`acpmux run --host NAME -m HARNESS "Reply only: pong"`). It
   fails with a sign-in message when the agent is signed out there.
2. On a cmux Cloud machine, the image signs Claude and Codex in through
   CodeRouter by default; the chat's sign-in card (`_acpmux/agent_login`)
   signs in the user's own account there without the Mac's login leaving
   the Mac.
3. On a machine of the user's (a mini, a laptop) that is signed out: one
   sign-in step for the user, through `escalate_auth` (kind `oauth` for
   `claude auth login` / `codex login --device-auth`, `password` for a
   provider page). Move the other chats meanwhile.

## Check it resumed

After the move, send one test prompt on the target and read the reply:

```bash
acpmux send HOST/ID "Reply with the last thing I asked you, in five words."
acpmux wait HOST/ID --timeout 300 && acpmux last HOST/ID
```

A reply that knows the chat's history is a resumed chat. A turn that fails
with a gateway or sign-in error is the target's model access, not the move:
fix that, then `acpmux retry HOST/ID`. A move that fails part way gives the
chat back here as it was; say which step failed.

## Telling the user

One line per chat: where it is now (machine and folder), whether the agent
resumed with its full context or from history only, and any sign-in still
needed on the target.
