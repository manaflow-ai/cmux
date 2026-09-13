# CmuxCloudMachines

Owns default-machine identity and fresh-fleet workspace creation. The application
constructs one selection model, injects its real auth and cloud operations into
`CloudWorkspaceCoordinator`, and owns the tasks launched by synchronous menus.

Tests need no app, network, or standard preferences:

```swift
let defaults = UserDefaults(suiteName: UUID().uuidString)!
let store = DefaultCloudMachineStore(defaults: defaults)
let coordinator = CloudWorkspaceCoordinator(
    defaultMachineStore: store,
    allowsOperation: { true },
    loadMachines: { [CloudMachineDescriptor(id: "machine", isDesktop: true)] },
    createWorkspace: { _, _ in UUID() }
)
let workspaceID = try await coordinator.createOnDefaultMachine(focus: true)
```

`CloudMachineResourcePresentation` validates and formats CPU, memory, and disk samples independently of app/provider types. The app maps its immutable machine snapshot at the UI boundary; missing and sleeping samples remain explicit. Localized labels use the host application's catalog.

```swift
let resources = CloudMachineResourcePresentation(
    availability: .awake, cpuPercent: 25,
    memoryUsedMb: 2048, memoryTotalMb: 4096
)
// resources.memory.percent == 50
```
