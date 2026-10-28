# Starting and showing agents: which surface for what

Three surfaces start, drive and show agent sessions. They share one daemon
(acpmux) and one worktree implementation (`src/subsession_worktree.rs`); pick
by who is calling, not by what is possible.

| You are | Start an agent for a task | Talk to it, wait | Show it to the person |
| --- | --- | --- | --- |
| A script, a person, or an agent with a shell | `acpmux new -n NAME --worktree REPO[@BASE] --prompt-file F --report-to ME --group G -d` | `acpmux send`, `acpmux wait`, `acpmux last` | `--group G` on the same command (runs `cmux agent open`) |
| An agent inside acpmux that wants a child of another harness, from its shell | `acpmux run --parent $ACPMUX_SESSION_ID -m codex PROMPT` (prints its reply), or `acpmux new --parent ... -d` | as below: it is the same sub-session | it lists under the parent's chat |
| An agent inside acpmux that wants a child (`cmux-subsessions` MCP) | `start_session {prompt, name, worktree: true}` | `send_message`, `wait_for_sessions`, `get_session` | `app_agent_open {session, group}` through the cmux MCP |
| The cmux app or an agent with the cmux MCP | the app's own New Chat, or one of the two above | the chat pane | `app_agent_open` (`cmux agent open SESSION [--group G]`), or a tab of a pane: `app_agent_open_tab` (`cmux agent open-tab SESSION --target PANE`) |

## The launcher: `acpmux new`

```bash
acpmux new -n gui/composer \
  --worktree ~/Projects/cmux@origin/feat-cmux-next \
  --prompt-file ~/briefs/composer.md \
  --report-to cosmic-gray/claude-sr2 \
  --group "GUI push" -m claude --policy approve-all -d
```

- **Worktree.** The daemon makes `~/.cmux/worktrees/<project>/<name>` on
  branch `cmux/<name>` (`<name>` is the session name, below) from BASE
  (default: REPO's current branch), laid out as the app's
  `git.worktree.create` lays one out, so Apply and Remove find it. A worktree already there is used as it is; a branch already there gets
  a new worktree (a failed fill then removes only the folder, never the
  branch); nothing is ever copied to `<name>-2`. Over the local unix
  socket only: on another machine, run the command there (`ssh HOST acpmux
  new ...`); `--worktree --host` is refused.
- **Prompt.** `--prompt-file` is read when the command runs, from its
  absolute path; a missing or empty file fails before anything starts. The
  first prompt is: who started the session and how to report back
  (`--report-to`), where its worktree is, the prompt words, then the file.
- **No questions.** Nobody sits at a launched session's chat, so it starts
  without Claude Code's AskUserQuestion (`--disallowedTools`, kept through
  respawns, resumes and restarts): a multiple-choice question there would
  wait for a pick that never comes. It decides, says why and goes on.
- **Idempotent.** Running the same command again gives the same session and
  worktree and sends nothing (`--reuse`, which `--worktree` implies), except
  the first prompt to a session that never got one (a launcher stopped
  before sending it). Two
  launchers racing on one name on one machine end with one session; the
  daemon makes one worktree at a time per name. A session of that name that
  has ended, or that works outside that worktree, is refused, not reused.
- **Names.** Any name with a letter or digit works: it is lowercased and
  every other run of characters becomes one `-`, at most 48 characters
  (`Gui/Composer` is session `gui-composer`, folder `gui-composer`, branch
  `cmux/gui-composer`); the name as given is the sidebar title.
- **Sidebar.** `--group G` runs `cmux agent open SESSION --group G` with a
  workspace key derived from the session id, so reopening the same session
  finds its row. Use `--name NAME --reuse` to reuse a launch; an unnamed launch
  creates a new session each time. A failed sidebar step warns; the prompt is
  still sent. It needs the cmux app on this machine. With `--host HOST`, the
  returned session ID is mirrored locally, so the workspace opens here while
  the agent runs there. A wrapper executing acpmux on HOST must omit `--group`
  there and run `cmux agent open ID --group G` on the controller Mac afterward.

## Wrapping it

A team script that starts lanes is the launcher plus its defaults, nothing
more. Everything a hand-written script used to check (an absolute brief
path, a second run, a name with `/`) the launcher already checks:

```bash
#!/bin/sh
# lane.sh NAME BRIEF [REPORT_TO]: one lane from the team's base, reporting to
# REPORT_TO (default: the session running this, when an agent runs it).
to=${3:-$ACPMUX_SESSION_NAME}
exec acpmux new -n "$1" -m claude --policy approve-all -d \
  --worktree ~/Projects/cmux@origin/feat-cmux-next --prompt-file "$2" \
  ${to:+--report-to "$to"}
```

On another machine, run it there (`ssh HOST lane.sh NAME BRIEF`, with the
brief on that machine): `--worktree` works over the local socket only.

## What not to use for this

- `acpmux ensure NAME` is get-or-create without a prompt or worktree; the
  launcher's `--reuse` is the same rule with both.
- A hand-written spawn script (`git worktree add` + `acpmux new` + `acpmux
  send`): it is the launcher without the checks. Wrap the launcher instead.
- `start_session` for long-lived lanes: a sub-session is a child of the
  calling session and is listed under it; start a lane with `acpmux new`.
