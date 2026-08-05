# CodeRouter CLI

CodeRouter gives Codex one command for a shared pool of Codex subscriptions.

```bash
cr add
cr codex
cr naked
```

`coderouter` and `cr` are equivalent executable names. With no command, `cr`
behaves like `cr codex` and forwards every argument to Codex.

## Commands

```text
cr [codex arguments...]       Codex through CodeRouter
cr codex [arguments...]       Codex through CodeRouter
cr naked [arguments...]       ordinary Codex, with CodeRouter bypassed
cr direct [arguments...]      alias for naked
cr add                        interactive Codex subscription setup
cr accounts                   list available subscriptions
cr usage                      show quota state
cr doctor                     diagnose login, vault, and local routing
cr login / cr logout          manage this machine's Stack Auth session
cr login --device-auth        copy a code into coderouter.dev/authorize
```

The interactive add flow either opens a fresh official Codex OAuth login in an
isolated `CODEX_HOME`, or shows the local import plan and asks for confirmation.
The
normal `~/.codex/auth.json` is not modified by the new-login flow.

CodeRouter currently supports Codex subscriptions only.

The production control plane is `https://coderouter.dev`. CodeRouter uses a
separate hosted-session config, so installing it does not reuse or overwrite a
generic Subrouter login. `CODEROUTER_API_URL` can override the control-plane
origin for staging and loopback development.

## Routing engine

The CLI uses the open-source Subrouter routing engine. It first honors
`CODEROUTER_SUBROUTER_BIN`, then an existing `subrouter` on `PATH`, then installs
the pinned release into the user's application-data directory after verifying
the release SHA-256 manifest.
