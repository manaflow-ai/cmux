# coderouter CLI

coderouter - route Codex/Claude Code traffic across multiple ChatGPT Pro/Claude Max/OpenCode subscriptions and API keys.

```bash
cr add
cr codex
cr pi
cr naked
```

`coderouter` and `cr` are equivalent executable names. With no command, they
show the account and usage summary. Agent routing is always explicit.

## Commands

```text
cr                           account and usage summary
cr codex [arguments...]       Codex through coderouter
cr opencode [arguments...]    OpenCode through coderouter
cr pi [arguments...]          Pi through coderouter (experimental)
cr naked [arguments...]       ordinary Codex, with coderouter bypassed
cr direct [arguments...]      alias for naked
cr add                        add Codex or OpenCode Go interactively
cr remove [account] [--yes]   remove a subscription
cr accounts                   list available subscriptions
cr usage                      show quota state
cr doctor                     diagnose login and the Vercel data plane
cr login / cr logout          manage this machine's coderouter session
cr login --device-auth        copy a code into coderouter.dev/authorize
```

The Ratatui add flow supports direct Codex OAuth/PKCE and OpenCode Go device
authorization. Direct Codex authentication has an explicit portable-PTY
fallback through the official CLI. Normal agent credentials are untouched.

The production control plane is `https://coderouter.dev`. coderouter uses a
separate session config and never overwrites normal agent configuration.
`CODEROUTER_API_URL` can override the origin for staging and loopback tests.

## Routing

The CLI routes directly to the Vercel data plane at `coderouter.dev`. It does
not install Subrouter, a local daemon, Go code, or GCP tooling.

`cr pi` creates an ephemeral Pi provider extension for the current process. It
captures the route token during extension startup and immediately removes it
from Pi's process environment before tools can inherit it. It never writes the
token to Pi config and leaves normal providers, settings, extensions, and
sessions untouched.
