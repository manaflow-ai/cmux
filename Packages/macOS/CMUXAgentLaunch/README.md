# CMUXAgentLaunch

`CMUXAgentLaunch` owns reusable launch, resume, and local Vault-indexing behavior
for supported coding agents.

Filesystem-backed indexes accept explicit roots so tests and downstream tools do
not need a real agent installation. For example:

```swift
let index = CursorSessionIndex(
    projectsRoot: fixture.appendingPathComponent("projects"),
    hookStoreURL: fixture.appendingPathComponent("cursor-hook-sessions.json")
)
let result = await index.loadSessions(
    needle: "regression",
    workingDirectoryFilter: nil,
    offset: 0,
    limit: 20
)
```
