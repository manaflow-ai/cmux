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
without host network or home-directory access. MCP-capable harnesses can use
the matching `cmux_docs` and `cmux_exec` tools.

Cloud and CUA operations will appear here after their owner relays join the
merged catalog. Do not connect a script to a cloud or CUA socket directly.
