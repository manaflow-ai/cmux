# CmuxCloudMachines

Owns Cloud workspace target resolution and existing-machine workspace creation. The
application injects authenticated scope, the actual right-sidebar order, and cloud
operations into `CloudWorkspaceCoordinator`; synchronous menus only start its task.

Tests need no app, network, or standard preferences:

```swift
let pins = CloudMachinePinStore(
    defaults: UserDefaults(suiteName: UUID().uuidString)!,
    scopeProvider: { "user:a|team:one" }
)
let coordinator = CloudWorkspaceCoordinator(
    machinePinStore: pins,
    allowsOperation: { true },
    loadMachines: { ["machine"] },
    createWorkspace: { request in
        _ = request.machineID
        return UUID()
    }
)
let windowID = UUID()
let state = coordinator.makeSelectionState()
state.select(workspaceID: UUID(), machineID: "machine")
let workspaceID = try await coordinator.createOnResolvedMachine(
    selection: state.lastCloudSelection, windowID: windowID, scopeID: "user:a|team:one"
)
```

`CloudMachinePinStore` owns explicit machine pins and the stable fleet order the
Machines panel shows, per account/team scope. Pinned machines sort first; within
each group machines keep their chosen order (initially first-seen), so refreshes and
asynchronous loading never shuffle the fleet. The order is passed to the resolver;
there is no separate default-machine preference.

```swift
let pinDefaults = UserDefaults(suiteName: UUID().uuidString)!
let pins = CloudMachinePinStore(defaults: pinDefaults, scopeProvider: { "user:a|team:one" })
pins.reconcile(machineIDs: ["b", "a"])   // the complete visible fleet; absent ids lose their pin
pins.setPinned(true, machineID: "a")
pins.orderedMachineIDs(["b", "a"])       // ["a", "b"]
pins.remember(machineIDs: ["c"])        // partial discovery never prunes saved identities
pins.move(.before("b"), machineID: "c", machineIDs: ["a", "b", "c"])
pins.orderedMachineIDs(["c", "b", "a"])  // ["a", "c", "b"]; pin membership is unchanged
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
