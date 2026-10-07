---
name: integrate-harness
description: Add the user's coding-agent harness (a company CLI, an ACP adapter, or a plain terminal tool) to cmux as a profile file, then prove it works with `cmux harness doctor`.
---

# Integrate a harness into cmux

You are helping the user add a coding-agent harness to cmux. A harness is one
TOML file in `~/.config/cmux/harnesses/<id>.toml`. cmux reads it without a
restart. You write the file, run the doctor, fix what it reports, and repeat
until every step passes.

## The loop

1. Ask the user which program they run and how they log in. Find it:
   `command -v <program>`. Read its `--help` and look for an ACP mode
   (`acp`, `--acp`, `--experimental-acp`, `--mode acp`) or a published ACP
   adapter (`<name>-acp`).
2. Start the file: `cmux harness add <id> --command <program>` (ACP) or
   `cmux harness add <id> --command <program> --protocol terminal` (no ACP).
   For a known agent start from an example: `--example claude|codex|opencode|pi|gemini|aider`.
3. Edit the file (schema below).
4. Run `cmux harness doctor <id>`. It starts the harness in a temp folder,
   runs `initialize`, `session/new` and one prompt, and prints PASS/WARN/FAIL
   per step with a `fix:` line. Do what the fix says, then run doctor again.
   Use `--no-prompt` when the user does not want a model call.
5. When doctor says `ready`, tell the user the harness now shows in the cmux
   model picker. `cmux harness list` shows every harness and its source.

## Rules

- Never write a secret (API key, token, password) into the file. Store it in
  the Keychain: `cmux harness secret set <id> <KEY>` (the user types the value),
  and reference it: `KEY = { keychain = "cmux-harness/<id>/<KEY>" }`.
  Values from the user's shell: `KEY = { env = "KEY" }`.
- Never print or echo env values. Doctor masks them; you must too.
- The file must be writable only by the user (`chmod 600`).
- The file name is the id: `acme.toml` has `id = "acme"` (lowercase letters,
  digits, `-`).
- A profile in a repository (`.cmux/harnesses/`) runs only after the user
  trusts the folder and confirms "Enable harness" with the command shown:
  `cmux harness list --folder DIR` shows its state, the user runs
  `cmux harness enable <id> --folder DIR` (and `disable` to withdraw). Any
  change to the file, its icon or a script inside the folder that it runs
  asks again. Never pass `--yes` for the user and do not try to get around it.

## Schema (schema 1)

```toml
schema = 1
id = "acme"                     # = file name
name = "Acme Agent"             # display name
icon = "acme.svg"               # file next to the profile (svg/png, <= 256 KB), or
                                # claude, openai, codex, opencode, pi, gemini, terminal, generic
protocol = "acp"                # acp | terminal | claude-stdio
command = "acme-agent"          # program on PATH, or an absolute path (no spaces, no arguments)
args = ["acp", "--model", "${model}"]   # ${model} = chosen model, ${cwd} = session folder
family = "acme"                 # optional; groups profiles for `-m acme`
fallback = "acme-backup"        # optional; profile to move to on a usage limit

[env]
ACME_REGION = "us-east-1"
ACME_API_KEY = { keychain = "cmux-harness/acme/ACME_API_KEY" }
ACME_HOME = { env = "ACME_HOME" }

[defaults]
model = "acme-large"
effort = "medium"               # none minimal low medium high xhigh max
policy = "ask"                  # ask approve-reads approve-edits approve-all deny-all

[capabilities]
effort = ["low", "medium", "high"]
fast = false
permission_modes = true
resume = true

[models]
list = [
  { id = "acme-large", name = "Acme Large", short_name = "Large", family = "Acme", efforts = ["low", "medium", "high"], default_effort = "medium", fast = false, context_window = 200000 },
  "acme-small",
]                               # each { … } stays on one line (TOML inline tables)

[auth]
login = "acme-agent login"      # shown when doctor finds no login
docs = "https://acme.example/agent/setup"
check = ["acme-agent", "whoami"]  # exit 0 = logged in

[sessions]                      # where its chats are, for the cmux Chats list
adapter = "jsonl"               # or a built-in: claude-code codex opencode pi gemini cursor-agent amp aider
roots = ["${ACME_HOME:-~/.acme}/sessions"]
files = "*/*.jsonl"
[sessions.fields]
id = "file.stem"
title = ["last:/title", "first:/message/content"]
cwd = "first:/cwd"
updated = "file.mtime"
[sessions.resume]
argv = ["acme-agent", "--resume", "{id}"]
cwd = "{cwd}"
```

Unknown keys are errors, so a typo shows in doctor with its line.

## When the harness has no ACP

Use `protocol = "terminal"`. cmux runs it in a terminal tab
(`cmux harness run <id>`) instead of a chat. Doctor only checks that the
program starts. If the vendor has an ACP adapter, prefer it: chats get
streaming, tool calls, permissions and model switching.

## Where cmux looks

1. `/Library/Application Support/cmux/harnesses/` (macOS) or `/etc/cmux/harnesses/`
   (Linux): managed by the company; wins over the user's files.
2. `~/.config/cmux/harnesses/` (or `$XDG_CONFIG_HOME/cmux/harnesses/`).
3. `~/.config/cmux/cmux.json`, key `agents.harnesses.<id>` (same keys, as JSON).
