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
