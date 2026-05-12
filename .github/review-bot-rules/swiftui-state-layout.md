# SwiftUI State And Layout

Flag new SwiftUI patterns that are known to cause stale state, excess invalidation, layout instability, or main-thread churn.

Report a failure when the diff introduces or materially expands:

- `ObservableObject`, `@Published`, `@StateObject`, or `@EnvironmentObject` for new cmux-owned SwiftUI state where `@Observable` plus `@State` or value snapshots are the modern shape.
- `GeometryReader` for measurement when `onGeometryChange` or a localized background measurement would avoid changing layout behavior.
- A `LazyVStack`, `LazyHStack`, `List`, or `ForEach` row subtree that holds a store reference (`@ObservedObject`, `@EnvironmentObject`, `@StateObject`, `@Bindable`, or a plain store property) instead of immutable snapshots plus action closures.
- State mutation from `body` or helpers called by `body`, including scheduling `Task { @MainActor ... }` or `DispatchQueue.main.async` to write state during render.

Allowed cases:

- Existing legacy view state that the PR only touches incidentally.
- `GeometryReader` as a contained fallback for older OS support or platform APIs, when it cannot affect parent layout and the reason is clear.
- AppKit bridge views where SwiftUI observation is not the owner of state.

cmux-specific emphasis:

- Large list and sidebar rows must receive value snapshots and closures. Store references below lazy list boundaries can re-render every row and create CPU spin loops.
- Render-time state writes are correctness bugs. They belong in explicit lifecycle callbacks, model observers, reload completions, or event handlers.

When reporting, identify the changed view boundary and suggest the snapshot/action or `@Observable` replacement.
