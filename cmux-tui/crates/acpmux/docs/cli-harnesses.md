# Agent harnesses, presets and defaults

A harness is the agent program a session runs: Claude Code, Codex, OpenCode, pi, Gemini, or one you
add. `-m HARNESS[/MODEL]` picks one for a session. Each `harness` command's `--help` lists every
flag and ends with examples.

## Harnesses

| Task | Command |
| --- | --- |
| Every harness, its kind, source file and problems | `cmux agent harness list` |
| Check one end to end: handshake and one prompt | `cmux agent harness doctor codex` |
| The handshake only, no model call | `cmux agent harness doctor codex --no-prompt` |
| Sign in to one | `cmux agent harness login gemini` |
| Add one from the shipped examples | `cmux agent harness add --example codex` |
| Add a CLI that does not speak ACP | `cmux agent harness add aider --command aider --protocol terminal` |
| Store an endpoint key for one | `cmux agent harness secret set acme ANTHROPIC_AUTH_TOKEN` |
| Allow a repo's own harness profile | `cmux agent harness enable review --folder ~/src/app` |
| Make the daemon read the profile files again | `cmux agent harness reload` |
| Move a profile to backups, and bring it back | `cmux agent harness remove acme`, then `cmux agent harness restore FILE` |
| Agents in the ACP Registry | `cmux agent harness registry` |
| The guide for integrating a harness | `cmux agent harness guide` |

Profiles live in `~/.config/cmux/harnesses/<id>.toml`.

## Presets and defaults

| Task | Command |
| --- | --- |
| Every preset | `cmux agent preset` |
| Save a harness, model and effort under one name (`-p astra`) | `cmux agent preset astra harness=codex model=gpt-6-astra effort=high` |
| Remove a preset | `cmux agent preset astra --clear` |
| The defaults for a model family | `cmux agent defaults claude` |
| Change them | `cmux agent defaults claude effort=high` |
| Clear one key | `cmux agent defaults claude effort=` |
| The model ids each harness offers | `cmux agent daemon models` |

See also [sessions](cli-sessions.md) and [the daemon](cli-daemon.md).
