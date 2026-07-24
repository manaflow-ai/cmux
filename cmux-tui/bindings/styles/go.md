# Go Binding Style

Go generation is not run this round.

Future requirements:

- Use `context.Context` on every command method.
- Use exported Go method names and JSON tags matching wire names.
- Provide typed errors that support `errors.Is` and `errors.As`.
- Expose event and attach streams with context-aware receive methods.
- Preserve raw JSON escape hatches for forward compatibility.
