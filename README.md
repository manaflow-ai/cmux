# CodeRouter CLI

CodeRouter gives coding agents one command for a shared subscription pool.

```bash
cr add
cr codex
cr naked
```

`coderouter` and `cr` are equivalent executable names. With no command, they
show the account and usage summary. Agent routing is always explicit.

## Commands

```text
cr                           account and usage summary
cr codex [arguments...]       Codex through CodeRouter
cr opencode [arguments...]    OpenCode through CodeRouter
cr naked [arguments...]       ordinary Codex, with CodeRouter bypassed
cr direct [arguments...]      alias for naked
cr add                        add Codex or OpenCode Go interactively
cr accounts                   list available subscriptions
cr usage                      show quota state
cr doctor                     diagnose login and the Vercel data plane
cr login / cr logout          manage this machine's Stack Auth session
cr login --device-auth        copy a code into coderouter.dev/authorize
```

The Ratatui add flow supports direct Codex OAuth/PKCE and OpenCode Go device
authorization. Direct Codex authentication has an explicit portable-PTY
fallback through the official CLI. Normal agent credentials are untouched.

The production control plane is `https://coderouter.dev`. CodeRouter uses a
separate session config and never overwrites normal agent configuration.
`CODEROUTER_API_URL` can override the origin for staging and loopback tests.

## Routing

The CLI routes directly to the Vercel data plane at `coderouter.dev`. It does
not install Subrouter, a local daemon, Go code, or GCP tooling.
