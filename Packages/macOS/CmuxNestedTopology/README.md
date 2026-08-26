# CmuxNestedTopology

`CmuxNestedTopology` is the provider-neutral domain model for virtual terminal-multiplexer descendants hosted inside a cmux terminal surface. It establishes the first foundation from [cmux #8737](https://github.com/manaflow-ai/cmux/issues/8737) without taking ownership of provider PTYs.

This package contains only immutable values, validation, and pure reduction. It does not connect to Herdr, create Bonsplit panes or Ghostty surfaces, attach to a cmux workspace, publish UI, forward actions, or persist a live inner tree.

## Ownership boundary

- cmux continues to own outer windows, workspaces, panes, panels, terminal surfaces, and stable surface identity.
- A nested provider owns its inner workspaces, tabs, panes, agents, layout, processes, and PTYs.
- A future attachment layer binds one validated provider snapshot beneath one host stable surface. It does not convert virtual descendants into native cmux panes.

## Identity and generations

`NestedNodeID` is structured and versioned. Equality includes provider kind, provider instance value, connection generation, node kind, and the opaque provider node ID. A reconnect generation therefore invalidates old node identities even when a socket path and raw provider ID are reused.

Opaque provider kinds, instance values, node IDs, capability tokens, and session IDs use exact UTF-8 identity rather than Swift `String` canonical equivalence. Providers may therefore use canonically equivalent Unicode representations as distinct protocol identifiers without collisions.

Their Codable wire values use a versioned `cmux-utf8-v1:` base64 envelope while public APIs remain `String`-based. The ASCII envelope prevents Darwin Foundation from consuming a leading U+FEFF as a byte-order mark during JSON decoding. Raw provider status values use the same lossless representation so forward-compatible states remain verbatim.

The provider instance raw value may come from a server-lifetime protocol identifier. When a provider does not expose one, its adapter must generate an opaque value and always generate a fresh connection generation. Socket paths and agent session IDs are never provider identity.

## Constructing validated state

Adapters construct node values, then cross the validation boundary through `NestedTopologySnapshot` or `NestedTopologyReducer.makeSnapshot`:

```swift
let provider = NestedProviderIdentity(
    kind: .herdr,
    instanceID: NestedProviderInstanceID(
        rawValue: serverInstanceValue,
        generation: connectionGeneration
    )
)

let snapshot = try NestedTopologySnapshot(
    provider: provider,
    capabilities: NestedProviderCapabilities([.topologySnapshot, .topologyEvents]),
    workspaces: workspaces,
    tabs: tabs,
    panes: panes,
    agents: agents,
    focus: focus
)

let next = try NestedTopologyReducer().applying(event, to: snapshot)

let locked = try NestedTopologyReducer().applying(
    .user(nodeID: paneID, value: userTitle),
    to: next
)
```

Provider snapshots and events may carry only `.inferred` or `.provider` title
authority. Host and user locks use the separate `NestedTopologyTitleChange`
path shown above; this prevents provider-controlled DTOs from claiming
cmux-owned provenance.

Published snapshots guarantee:

- one provider identity and generation across all nodes and parents;
- fixed workspace → tab → pane → agent parent kinds with every parent present;
- deterministic sibling order independent of display titles;
- one coherent focused path;
- bounded counts, depth, identifiers, titles, status values, sessions, and capabilities;
- bounded event batches with indexed mutation and one ordering publication pass;
- unknown provider capabilities and raw agent statuses remain available for forward compatibility;
- duplicate creates are idempotent only when content matches, unknown updates fail for resynchronization, and closes cascade;
- a successful pane/session heuristic becomes the resolved topology parent used
  for hierarchy, focus, and close cascades; it applies once and provider
  parentage remains authoritative when later available;
- inferred titles cannot overwrite provider, host, or user title authority;
- a provider update with no title clears inferred/provider titles while host and
  user title locks remain intact.

Every event carries provider identity separately, including focus-clear events. Reducers reject a stale generation before applying any mutation.

Snapshots remember the validation policy that accepted them, so a reducer with stricter limits revalidates even no-op events. Limits are trust policy rather than provider data and are not serialized. To decode data that was accepted under custom limits, put the same `NestedTopologyLimits` value in `JSONDecoder.userInfo` under `NestedTopologySnapshot.decodingLimitsUserInfoKey`; decoding otherwise uses a freshly constructed `NestedTopologyLimits()` value with production defaults.

Snapshot decoding stops before materializing node or capability collections beyond those limits and validates each decoded value before retaining the next one. It defaults to `NestedTopologySnapshotDecodingMode.providerInput`, which rejects host and user title locks. Only cmux-owned serialization of an already-published snapshot may set `NestedTopologySnapshot.decodingModeUserInfoKey` to `.trustedPublishedSnapshot`; provider adapters must never use that mode. A `Decoder` cannot report the original frame byte count, so socket and file adapters must additionally cap the raw payload before creating `JSONDecoder`; that transport boundary belongs to the planned provider adapter rather than this model package.

## Planned consumers

The package is the common seam for a stacked implementation:

1. a read-only Herdr socket adapter;
2. secure host-surface attachment lifecycle;
3. provider-owned sidebar and opt-in control-tree projection;
4. capability-gated action routing;
5. revalidated restore intent and plugin single-writer coexistence.

The existing tmux mirror may project into this model later, but it keeps its current local mirrored-PTY ownership. This package does not force unlike providers into the same transport or process-lifecycle strategy.

## Tests

Run the standalone deterministic behavior suite without launching cmux:

```bash
swift test --package-path Packages/macOS/CmuxNestedTopology
```
