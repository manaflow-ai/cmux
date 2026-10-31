---
name: chief-vault
description: Get and use the person's credentials (API keys, tokens) without ever seeing them, through the cmux vault. Use whenever a task needs a key or token, or the person pastes or offers one.
cmux-managed: true
---

# Credentials through the vault

The person hands cmux credentials once, in the vault; you and your
subagents use them by name and never see a value. A value never goes into
a chat, a reply, a file, a commit, memory or a command line.

## 1. See what is there

`cmux vault ls --json` lists names, their scope (`user`, `agents`), a note
and when each was last used. Never a value.

## 2. Ask for one that is missing

Never ask the person to paste a key in the chat. Ask through cmux, which
shows them a secure sheet:

    cmux vault request OPENAI_API_KEY --reason "run the eval against the OpenAI API"

It waits until they save or cancel (up to 10 minutes) and answers
`{"stored": "OPENAI_API_KEY", ...}` or a `declined` error. Name it the way
the program reads it (`GH_TOKEN`, `OPENAI_API_KEY`, `STRIPE_API_KEY`). Say in
one line what you asked for and why; then wait, do not ask again in chat.

## 3. Use one

Run the command with the secret in its environment:

    cmux vault exec --env GH_TOKEN -- gh pr list
    cmux vault exec --env OPENAI_API_KEY=WORK_OPENAI_KEY -- python3 eval.py

`--env VAR` fills `VAR` from the secret of the same name; `VAR=NAME` fills
`VAR` from secret `NAME`. The command's output is masked: a value it prints
shows as `[vault:NAME]`. Give the same command to a subagent; it works the
same way. Never `echo`, `printenv`, write or upload a value, and never copy
one into a config file: run the tool through `cmux vault exec` each time.

## 4. Refusals

- `vault.missing`: the name is not there; ask with `cmux vault request`.
- `vault.denied`: the person keeps it for themselves (scope `user`). Tell
  them in one line which name and why you need it; only they change the
  scope (Settings > Credential Vault, or `cmux vault scope NAME user,agents`).
- `vault.user_only`: only the person adds, changes or removes secrets.
- `vault.not_approved`: the person did not allow it on their cmux sheet.
  Do not retry, and never try to get around a refusal (another env, another
  terminal, another caller): tell them in one line what you needed.

## 5. A pasted secret

If the person pastes a key or token in the chat anyway, do not repeat it.
cmux offers them to move it to the vault before it is sent; if one reached
you, tell them in one line to remove it from the chat and add it with the
vault (Settings > Credential Vault > Add, or `cmux vault set NAME` in a terminal),
then use it by name.

`cmux vault log` shows every use: who, which command, granted or refused.
