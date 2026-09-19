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

`CloudMachineResourcePresentation` validates and formats CPU, memory, and disk samples independently of app/provider types. The app maps its immutable machine snapshot at the UI boundary; loading, missing, stale, and sleeping samples remain explicit. Localized labels use the host application's catalog.

```swift
let resources = CloudMachineResourcePresentation(
    availability: .awake, cpuPercent: 25,
    memoryUsedMb: 2048, memoryTotalMb: 4096
)
// resources.memory.percent == 50
```

`CloudMachineCreateCoordinator` owns pending creates, retry fences, cancellation
receipts, and adoption aliases. Reserve synchronously before launching I/O; feed
progress and completion back with the returned `CloudMachineCreateAttempt`. Apply
`CloudMachineCreateTransition` effects only after the state transition. The app
adapter owns processes, redaction, localized labels, notifications, and workspaces.
No package test needs to launch AppKit or a process:

```swift
let owner = CloudMachineCreateCoordinator(
    output: CloudMachineCreateOutput(legacyCreatedFormat: "Created Cloud VM %@"),
    now: { Date(timeIntervalSince1970: 123) }
)
let workspaceID = UUID()
let request = CloudMachineCreateRequest(
    arguments: ["vm", "new", "--workspace", workspaceID.uuidString],
    isBaseSetup: false, presentationWorkspaceID: workspaceID,
    retainsPendingProjection: true
)
let attempt = owner.reserve(request)
// owner.projection already contains the pending row before starting the launcher.
let teardown = owner.cancelPresentations([workspaceID])
// teardown never requests another workspace close.
```

Adoption aliases persist for the account session, including after a successful
operation retires. This uses one small mapping per created machine so coalesced,
partial, and out-of-order panel refreshes cannot change row identity. Cancellation
tombstones remain until process termination instead of evicting live receipts.
Retries retain their original CLI idempotency scope; backend allocation durability
and the CLI's idempotency store remain outside this package.
