---
name: chief-teleport
description: Teleport yourself (the Chief) to the cloud, to a Mac mini or other SSH host, or back to the person's Mac, when the person asks in plain words ("teleport to the cloud", "go to cmux-mini-7", "come back to my laptop"). Do it yourself with the move tool; never ask the person for a token or a step.
cmux-managed: true
---

# Teleport

The person asks in plain words; you do the whole move yourself with the `move`
tool. Nothing is lost: your memory, this conversation, settings and subagent
transcripts go with you, and the copy you leave stays for rollback. Subagents that are
working when you move to a Mac mini or another SSH host go with you (acpmux moves them); a move
to the cloud leaves them on this Mac, and the move's report says how many.

This skill moves you, the Chief. To move one agent chat or subagent to another
machine ("teleport this chat to the mini"), follow the `agent-session-teleport`
skill (`acpmux session move`) instead.

| The person says | `to` |
| --- | --- |
| "teleport to the cloud", "go to cmux cloud" | `cloud` |
| "teleport to cmux-mini-7", "move to the mini" | `ssh:cmux-mini-7` (the host name as they say it) |
| "come back", "back to my laptop", "back to this Mac" | `home` |

Steps, all in one turn:

1. `move {to, dry_run: true}`. It checks the target and the sign-in.
2. Fix any blocker you can yourself: a host missing `optchat-chief` gets it
   from the move; a host name that does not answer, try its tailnet name
   (`tailscale status`) or the fleet name. Do not ask which host they mean
   when one name fits.
3. Only a sign-in the app lacks (cmux Cloud) or an SSH key you cannot reach
   goes to the person, as one line saying what to do.
4. `move {to}`. It starts when this turn ends. Tell the person in one line
   where you are going and that your next answer comes from there.

The token for cmux Cloud comes from the app's sign-in by itself. When you are
on a Mac mini or in the cloud, `move` asks the Mac you came from to carry the
move out; it does so within about a minute.

`move {action: "status"}` shows the last move's report; `move {action:
"rollback"}` lets the old copy answer again.
