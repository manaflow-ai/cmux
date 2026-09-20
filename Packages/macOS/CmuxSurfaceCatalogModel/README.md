# CmuxSurfaceCatalogModel

The surface catalog's value types: the vocabulary shared by `SurfaceCatalog`, the Cloud sidebar, the socket commands and the CLI. Pure `Hashable`/`Codable`/`Sendable` values plus the cmux-tui snapshot parser that produces them. No app imports; depends on `CmuxCore` and `CMUXDebugLog`.

```swift
import CmuxSurfaceCatalogModel

let id = SurfaceResourceID(machine: .cloud("vm-1"), kind: .terminal, key: "t1")
assert(SurfaceResourceID(rawValue: id.rawValue) == id)
```

`SurfaceCatalog` itself (the owner, `@MainActor`, app-coupled) stays in the app target.

## Moved files

From `Sources/Surfaces/`: `SurfaceCatalogModel.swift`, `SurfaceCatalogSnapshot.swift`, `SurfaceResourcePlacement.swift`, `CloudVMTabState.swift`, `CloudTabNameAuthority.swift`, `CloudTabNameSource.swift`, `CmuxTuiSnapshotParser.swift`, `CloudVMState+SnapshotComparison.swift` (it holds `CloudVMState`'s `==`).
From `Sources/Cloud/`: `VMMachineKind.swift` (was also a member of the `cmux-cli` target, so the CLI links this package), `CloudTuiTerminalProjectionTarget.swift`.

`SurfaceResourceID+Ports.swift` is new: the parser's listening-port helpers (from `SurfaceCatalog+CloudPorts.swift`) and `SurfaceResourceID.portKey`/`desktopDisplayKey` (from `SurfaceSocketCommands.swift`), which the moved parser calls.

## What changed besides the move

- Declarations became `public`. Structs that relied on the synthesized memberwise initializer got an explicit `public init` with the same parameters and defaults.
- `cmuxDebugLog(...)` (an app global) became `CMUXDebugLog.logDebugEvent(...)`, still under `#if DEBUG`.
