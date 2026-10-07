# Harness manifests

A harness is any coding agent cmux can drive over the Agent Client Protocol
(ACP). Adding one takes a folder, no code: a `harness.json` and an icon.

```
~/.config/cmux/harnesses/        next to cmux.json ($XDG_CONFIG_HOME/cmux/harnesses)
  acme/
    harness.json
    icon.svg
```

`cmux harness add acme` (or `acpmux harness add acme`) creates that folder with every field filled in. Edit
it, then run `cmux harness check acme`. A running daemon picks up a saved
change within a few seconds; open chats keep running on what they started with.

## harness.json

```json
{
  "schema": 1,
  "id": "acme",
  "name": "Acme Agent",
  "description": "Acme's internal coding agent",
  "homepage": "https://acme.example/agent",
  "icon": "icon.svg",
  "run": {
    "protocol": "acp",
    "command": "acme-agent",
    "args": ["--acp"],
    "env": { "ACME_REGION": "us" },
    "install": "brew install acme/tap/acme-agent"
  },
  "auth": {
    "logins": [
      { "id": "sso", "label": "Acme SSO", "args": ["login", "--sso"] }
    ],
    "status": ["whoami"]
  },
  "models": { "source": "acp", "list": [{ "id": "acme-large", "name": "Acme Large" }] },
  "capabilities": { "fast": "fast", "effort": "effort", "permissions": true, "resume": true },
  "defaults": { "model": "acme-large", "effort": "medium", "policy": "ask" },
  "family": "acme"
}
```

| Field | Required | Meaning |
| --- | --- | --- |
| `schema` | yes | `1`. |
| `id` | yes | Same as the folder name: 1-32 lowercase letters, digits and dashes, starting with a letter. It is the name in `acpmux new -m acme` and in config.json. |
| `name` | yes | What the picker and New Tab show (up to 40 characters). |
| `description`, `homepage` | no | Shown in the harness's details. |
| `icon` | no | An `.svg` file in the folder. Draw it in `currentColor` so it follows light and dark themes. No scripts, event handlers, `<image>`, `<use>`, `<foreignObject>` or outside URLs; `check` names what it refused. Without one, pickers show the name's initials. |
| `run.protocol` | no | `acp` (default) or `claude-stdio` (Claude Code's stream-json). |
| `run.command` | yes | A program on your login PATH, or an absolute path. One program; arguments go in `run.args`. |
| `run.args` | no | Arguments that start the agent's ACP server on stdio. |
| `run.env` | no | Extra environment. Names may not start with `ACPMUX_`. Put secrets in the agent's own login, not here. |
| `run.install` | no | How to install the command; shown when it is missing. |
| `auth.logins` | no | Ways to sign in. The app runs `command args…` in a terminal tab, so interactive and browser logins work. |
| `auth.status` | no | Args for `command` that exit 0 when signed in. |
| `models.source` | no | `acp` (default): the models the agent reports. `static`: only `models.list`. |
| `models.list` | no | Models shown ahead of what the agent reports; required for `static`. A string or `{id, name}`. |
| `capabilities` | no | ACP config option ids for `fast` and `effort`, so the composer shows those controls; `permissions` when the agent asks before running tools; `resume` when `session/load` reopens a chat after a restart. |
| `defaults` | no | Model, effort and permission policy for new chats. `policy` is `ask`, `approve-reads`, `approve-edits`, `approve-all` or `deny-all`. |
| `family` | no | Groups harnesses for `defaults` in config.json; the id when absent. |

Unknown fields are errors, so a typo is caught instead of ignored.

## Which entry wins

1. A `harnesses` entry in `~/.acpmux/config.json` with the same id.
2. Your manifest in `~/.config/cmux/harnesses/`.
3. A manifest that ships with acpmux.
4. An agent found on PATH (`codex-acp`, `opencode`, `gemini`, ...).

A manifest whose command is not installed still appears, marked unavailable
with its `run.install` hint.

## Share a harness with your team

Commit the folder to a repository, in `.cmux/harnesses/<id>/` (or
`harnesses/<id>/`, or the repository root for a repository that is only the
harness). Teammates install it with one command:

```
cmux harness add --from git@github.com:acme/agent-harness.git
cmux harness add --from ~/src/acme-app acme      # one harness from a checkout
```

`add --from` checks every manifest before installing it and copies only
`harness.json` and its icon; scripts in the repository never run. A harness
of the same id needs `--replace`.

A project that ships `.cmux/harnesses/` is noticed when you work in it:
`_acpmux/harnesses` with that `cwd` lists its harnesses under
`projectHarnesses`, with whether you have installed them and whether yours
differs, so the app can offer to install them. Nothing from a project folder
runs until you install it.

## Check

```
$ acpmux harness check
ok   acme: Acme Agent (/opt/homebrew/bin/acme-agent --acp)
FAIL broken (~/.config/cmux/harnesses/broken)
     run.command: one program, no spaces; put arguments in run.args
     icon: icon.svg has a <script>
```

`check` takes nothing (all of yours), an id, or a folder, exits 1 when any
manifest has a problem, and prints JSON with `--json`. The daemon skips a
manifest that fails and lists it under `manifestProblems` in
`_acpmux/harnesses`.
