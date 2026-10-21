# Starting and showing agents: which surface for what

Three surfaces start, drive and show agent sessions. They share one daemon
(acpmux) and one worktree implementation (`src/subsession_worktree.rs`); pick
by who is calling, not by what is possible.

| You are | Start an agent for a task | Talk to it, wait | Show it to the person |
| --- | --- | --- | --- |
| A script, a person, or an agent with a shell | `acpmux new -n NAME --worktree REPO[@BASE] --prompt-file F --report-to ME --group G -d` | `acpmux send`, `acpmux wait`, `acpmux last` | `--group G` on the same command (runs `cmux agent open`) |
| An agent inside acpmux that wants a child (`cmux-subsessions` MCP) | `start_session {prompt, name, worktree: true}` | `send_message`, `wait_for_sessions`, `get_session` | `app_agent_open {session, group}` through the cmux MCP |
| The cmux app or an agent with the cmux MCP | the app's own New Chat, or one of the two above | the chat pane | `app_agent_open` (`cmux agent open SESSION [--group G]`) |

## The launcher: `acpmux new`

```bash
acpmux new -n gui/composer \
  --worktree ~/Projects/cmux@origin/feat-cmux-next \
  --prompt-file ~/briefs/composer.md \
  --report-to cosmic-gray/claude-sr2 \
  --group "GUI push" -m claude --policy approve-all -d
```

- **Worktree.** The daemon makes `~/.cmux/worktrees/<project>/<name>` on
  branch `cmux/<name>` from BASE (default: REPO's current branch), laid out
  as the app's `git.worktree.create` lays one out, so Apply and Remove find
  it. A worktree already there is used as it is; a branch already there gets
  a new worktree; nothing is ever copied to `<name>-2`. Over the local unix
  socket only: on another machine, run the command there (`ssh HOST acpmux
  new ...`); `--worktree --host` is refused.
- **Prompt.** `--prompt-file` is read when the command runs, from its
  absolute path; a missing or empty file fails before anything starts. The
  first prompt is: who started the session and how to report back
  (`--report-to`), where its worktree is, the prompt words, then the file.
- **Idempotent.** Running the same command again gives the same session and
  worktree and sends nothing (`--reuse`, which `--worktree` implies). Two
  launchers racing on one name end with one session.
- **Names.** Any name works: characters a session name may not hold (`/`,
  spaces) become `-` (`gui/composer` is session and branch `gui-composer`);
  the name as given is the sidebar title.
- **Sidebar.** `--group G` runs `cmux agent open SESSION --group G` with a
  workspace key derived from the name, so a second run finds the same row.
  It needs the cmux app on this machine; elsewhere leave it off and run
  `cmux agent open` on the Mac.

## What not to use for this

- `acpmux ensure NAME` is get-or-create without a prompt or worktree; the
  launcher's `--reuse` is the same rule with both.
- A hand-written spawn script (`git worktree add` + `acpmux new` + `acpmux
  send`): it is the launcher without the checks. Wrap the launcher instead.
- `start_session` for long-lived lanes: a sub-session is a child of the
  calling session and is listed under it; start a lane with `acpmux new`.
