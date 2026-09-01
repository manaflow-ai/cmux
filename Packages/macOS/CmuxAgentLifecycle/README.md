# CmuxAgentLifecycle

`CmuxAgentLifecycle` owns the pure, shared agent-lifecycle domain used by the
macOS app and CLI. It reconciles hook, native-attention, process-generation,
and structured-settlement evidence without reading the process table, opening
sockets, or touching UI state.

Executable targets provide platform evidence such as process liveness and then
pass values into the package:

```swift
var state = AgentLifecycleReconciliationState()
let generation = AgentProcessGeneration(
    pid: 42,
    startSeconds: 1_700_000_000,
    startMicroseconds: 10
)
state.recordProcessGeneration(
    key: BuiltInAgentIntegration.codex.statusKey,
    panelId: panelID,
    generation: generation,
    isBuiltIn: true
)
```

Package tests construct the domain values directly, so lifecycle ordering and
settlement behavior can be verified without launching cmux or reading a user's
filesystem.

Native-approval owners inject their UI-specific target into the bounded active
registry and synchronously retire every record returned by eviction or owner
teardown:

```swift
var observations = AgentObservedAttentionRegistry<PanelAttentionTarget>(
    maximumCount: 256
)
let evicted = observations.insert(
    AgentObservedAttentionRecord(
        key: observationKey,
        scopeId: turnScopeID,
        target: panelTarget
    )
) ?? []
for record in evicted {
    clearVisibleAttention(record.target)
}
```
