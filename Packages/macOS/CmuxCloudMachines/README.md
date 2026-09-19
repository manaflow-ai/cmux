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

`CloudMachinePinStore` owns explicit machine pins and the stable fleet order the
Machines panel shows, per account/team scope. Pinned machines sort first; within
each group machines keep the order they were first seen in, so refreshes and
asynchronous loading never shuffle the fleet. It is independent of the default
machine above: a pin is sidebar priority, the default is Cmd+Y routing.

```swift
let pinDefaults = UserDefaults(suiteName: UUID().uuidString)!
let pins = CloudMachinePinStore(defaults: pinDefaults, scopeProvider: { "user:a|team:one" })
pins.reconcile(machineIDs: ["b", "a"])   // the complete visible fleet; absent ids lose their pin
pins.setPinned(true, machineID: "a")
pins.orderedMachineIDs(["b", "a"])       // ["a", "b"]
```

`CloudMachineResourcePresentation` validates and formats CPU, memory, and disk samples independently of app/provider types. The app maps its immutable machine snapshot at the UI boundary; loading, missing, stale, and sleeping samples remain explicit. Localized labels use the host application's catalog.

```swift
let resources = CloudMachineResourcePresentation(
    availability: .awake, cpuPercent: 25,
    memoryUsedMb: 2048, memoryTotalMb: 4096
)
// resources.memory.percent == 50
```
