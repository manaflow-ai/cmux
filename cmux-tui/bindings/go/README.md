# cmux Go SDK

Package `cmux` exposes the typed `cmux.protocol/2` resource API. Package
`cmux/raw` preserves the private protocol-v12 API.

Install the released nested module with its semantic-version tag:

```bash
go get github.com/manaflow-ai/cmux/cmux-tui/bindings/go@v1.0.0
```

```go
client, err := cmux.NewClient(ctx, cmux.ClientOptions{})
if err != nil {
	log.Fatal(err)
}
defer client.Close(context.Background())

session := client.
	Machine(cmux.SelectCurrent[cmux.MachineID]()).
	Session(cmux.SelectCurrent[cmux.SessionID]())
workspace := session.Workspace(cmux.SelectCurrent[cmux.WorkspaceID]())
result, err := workspace.Run(ctx, cmux.WorkspaceRunOptions{
	Command: cmux.Exact("printf", "hello\n"),
})

agent, err := session.ReportAgent(ctx, cmux.AgentReportOptions{
	TerminalID: result.Value.Terminal,
	State:      cmux.AgentStateWorking,
	Source:     cmux.AgentReportSourceSocket,
})
```

`Exact` preserves argv without shell interpretation. `Shell` requests explicit
server-side shell execution. Resource handles do not own remote resources.
Only `Client` and typed streams require explicit close or cancellation.
`Session.ReportAgent` publishes the first agent state for a terminal and
returns the typed agent snapshot without requiring an earlier agent listing.

Mutations use caller-provided idempotency keys or keys generated from 128 bits
of secure random data. The client never retries mutations. `Decimal` encodes
the full unsigned 64-bit range as a canonical JSON string. Renderer grants
redact their values from formatted output.

Each `frame` item from `Browser.Attach` includes `PointerFrameSeq *Decimal`.
`nil` means the frame cannot authorize pointer input. Pass a non-nil frame's
exact value to `BrowserInputMouseOptions.PointerFrameSeq` or
`BrowserInputWheelOptions.PointerFrameSeq`; both inputs always encode the token
as an unsigned decimal string.

`ClientOptions.DialContext` supports injected transports and tests. The default
transport uses a Unix session socket, with a Windows-compatible build fallback
that requires injection.
