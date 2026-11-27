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

`CloudMachineDeletionCoordinator` owns optimistic machine deletion. `begin` hides a
machine from every list before the destroy request starts; a second `begin` for the
same machine is a no-op. On success or 404 the machine stays hidden as a confirmed
deletion; on failure its row is listed again. A pending deletion stays hidden
whatever a fleet read returns. A confirmed one stays hidden until the account ends:
provider machine IDs are never reused, and each list polls on its own schedule, so
no single read proves that every list has dropped the machine. The projection's
`hiddenMachineIDs` is what lists omit; `pendingMachineIDs` is the subset that can
still come back, so a view keeps rollback state only for those. `endAccount()`
forgets every entry without rollback. The app adapter owns the CLI, alerts, and
closing workspaces. Before closing the machine's workspaces it calls the create
owner's `retireCreates(producing:presentedIn:)` with their IDs, so a create for the
same machine stops without a second destroy request, even one whose receipt has
not named the machine yet. It closes no presentation in those workspaces, since
the adapter closes them whole, panes the person added included; a window's last
tab stays open, emptied and unbound. A cancelled create's `cleanupMachineIDs`
start deletions too, through `beginCleanup`, which hides the machine at once. Its
presentations close only when `beginRequest` reports the cleanup's destroy
request, after the create's presentation has closed, so a pane the person added
there stays open. A cleanup whose CLI exits before the request lists the machine
again with its presentations. After a failure the adapter calls
`machineDeletionFailed(_:)`, so a create whose receipt first names the restored
machine keeps it. The creates the delete stopped stay stopped, and
receipts seen while it ran request nothing, so no create retries the destroy on
its own. When the account ends, the create owner's `endAccount()` clears its
deletions without an outcome and counts their machines as cleaned up, so a
departed create never destroys one of them:

```swift
let deletions = CloudMachineDeletionCoordinator()
guard deletions.begin("m1") else { return }       // hidden before any request
_ = creates.retireCreates(producing: "m1", presentedIn: m1WorkspaceIDs)
// Now close m1's workspaces whole; none has a create left to cancel.
switch deletions.finish("m1", result: .deleted) {
case .retired: break                              // close local registrations; m1 stays hidden
case .restored:                                   // row is listed again; alert
    creates.machineDeletionFailed("m1")
case .ignored: break                              // duplicate, or the account ended
}
deletions.endAccount()                            // sign-out: both sets are empty
_ = creates.endAccount()                          // departed creates never destroy m1
```
