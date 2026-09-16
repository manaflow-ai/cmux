# CmuxCloudMachines

Owns explicit Cloud machine workspace creation. Callers capture a stable machine
identity from the current selection before starting an asynchronous request;
the coordinator validates that identity against the authoritative fleet and
never falls back to another machine.

Tests need no app, network, or standard preferences:

```swift
let coordinator = CloudWorkspaceCoordinator(
    allowsOperation: { true },
    loadMachines: { [CloudMachineDescriptor(id: "machine", isDesktop: true)] },
    createWorkspace: { _, _ in UUID() }
)
let workspaceID = try await coordinator.createOnMachine(machineID: "machine", focus: true)
```

`CloudMachineResourcePresentation` validates and formats CPU, memory, and disk samples independently of app/provider types. The app maps its immutable machine snapshot at the UI boundary; loading, missing, stale, and sleeping samples remain explicit. Localized labels use the host application's catalog.

```swift
let resources = CloudMachineResourcePresentation(
    availability: .awake, cpuPercent: 25,
    memoryUsedMb: 2048, memoryTotalMb: 4096
)
// resources.memory.percent == 50
```
