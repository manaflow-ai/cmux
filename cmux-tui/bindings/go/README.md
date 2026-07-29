# cmux Go SDK

Package `cmux` exposes the typed `cmux.protocol/1` resource API. Package
`cmux/raw` preserves the legacy protocol-v10 API.

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
```

`Exact` preserves argv without shell interpretation. `Shell` requests explicit
server-side shell execution. Resource handles do not own remote resources.
Only `Client` and typed streams require explicit close or cancellation.

Mutations use caller-provided idempotency keys or keys generated from 128 bits
of secure random data. The client never retries mutations. `Decimal` encodes
the full unsigned 64-bit range as a canonical JSON string. Sensitive provider
credentials and renderer grants redact their values from formatted output.

`ClientOptions.DialContext` supports injected transports and tests. The default
transport uses a Unix session socket, with a Windows-compatible build fallback
that requires injection.
