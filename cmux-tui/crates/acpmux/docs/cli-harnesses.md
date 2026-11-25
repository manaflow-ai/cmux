# acpmux CLI: harnesses, presets and defaults

A harness is the agent program a session runs: Claude Code, Codex, OpenCode, pi, Gemini, or one you
add. `-m HARNESS[/MODEL]` picks one for a session. Each `harness` command's `--help` lists every
flag and ends with examples.

## Harnesses

| Task | Command |
| --- | --- |
| Every harness, its kind, source file and problems | `acpmux harness list` |
| Check one end to end: handshake and one prompt | `acpmux harness doctor codex` |
| The handshake only, no model call | `acpmux harness doctor codex --no-prompt` |
| Sign in to one | `acpmux harness login gemini` |
| Add one from the shipped examples | `acpmux harness add --example codex` |
| Add a CLI that does not speak ACP | `acpmux harness add aider --command aider --protocol terminal` |
| Store an endpoint key for one | `acpmux harness secret set acme ANTHROPIC_AUTH_TOKEN` |
| Allow a repo's own harness profile | `acpmux harness enable review --folder ~/src/app` |
| Make the daemon read the profile files again | `acpmux harness reload` |
| Move a profile to backups, and bring it back | `acpmux harness remove acme`, then `acpmux harness restore FILE` |
| Agents in the ACP Registry | `acpmux harness registry` |
| The guide for integrating a harness | `acpmux harness guide` |

Profiles live in `~/.config/cmux/harnesses/<id>.toml`.

## Presets and defaults

| Task | Command |
| --- | --- |
| Every preset | `acpmux preset` |
| Save a harness, model and effort under one name (`-p astra`) | `acpmux preset astra harness=codex model=gpt-6-astra effort=high` |
| Remove a preset | `acpmux preset astra --clear` |
| The defaults for a model family | `acpmux defaults claude` |
| Change them | `acpmux defaults claude effort=high` |
| Clear one key | `acpmux defaults claude effort=` |
| The model ids each harness offers | `acpmux daemon models` |

See also [sessions](cli-sessions.md) and [the daemon](cli-daemon.md).
