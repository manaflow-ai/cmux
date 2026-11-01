# cmux code mode

Use the catalog before writing a script:

```sh
cmux docs search "pane split"
cmux docs search "terminal output"
```

Put related operations in one TypeScript file and run it through the
catalog-gated sandbox:

```sh
cmux run ./open-and-test.ts
```

The script receives a typed `cmux` Node client and `cmuxArgs`. The runner
allows only operations in the embedded cmux-tui catalog and keeps the sandbox
without host network or home-directory access. Linux requires `bwrap`; macOS
uses its deny-by-default Seatbelt profile. Both fail closed if unavailable.
MCP-capable harnesses can use `cmux_docs` and `cmux_exec`.

Scripts have a **30-second wall-clock run limit**, including time spent in tool
calls. Override it for one invocation with `CMUX_CODE_MODE_TIMEOUT_MS=120000
cmux run ./script.ts`, or pass `timeout_ms: 120000` to the Bun MCP `cmux_exec`.
The value must be a positive integer at most 2147483647 milliseconds; there is
no unbounded value. The timer runs in a host supervisor outside the sandbox,
so even a script spinning synchronously is stopped (CLI exit status 124).

Inside an acpmux chat, the supervisor attaches to the owning session's current
turn before launching the script. Turn completion/cancellation or session stop
ends the script and its entire sandbox. Losing the lifecycle connection also
stops it. Outside an acpmux chat the deadline and process signals still apply.
The MCP server additionally cancels executions when input closes or it receives
SIGINT/SIGTERM. Each run reaps its worker, clears its timers and event listener,
and removes its temporary proxy directory; MCP also removes its script file.

Cloud and CUA operations will appear here after their owner relays join the
merged catalog. Do not connect a script to a cloud or CUA socket directly.
