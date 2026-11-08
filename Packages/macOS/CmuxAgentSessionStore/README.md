# CmuxAgentSessionStore

`CmuxAgentSessionStore` owns validated, cached access to agent session-history
files. Vault depends on `AmpHookSessionReading`; the app constructs one
`AmpHookSessionRepository` at its composition boundary and injects it into
initial snapshot and search operations.

Tests can isolate filesystem state by injecting a scoped `FileManager` and a
temporary store URL:

```swift
let repository = AmpHookSessionRepository(fileManager: fileManager)
let sessions = try await repository.snapshots(
    at: temporaryStoreURL,
    matching: "query",
    workingDirectory: nil,
    offset: 0,
    limit: 50
)
```
