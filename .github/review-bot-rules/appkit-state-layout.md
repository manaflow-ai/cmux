# AppKit And UIKit State Layout

Flag native UI patterns that cause stale state, duplicate ownership, layout instability, or main-thread churn.

Report a failure when the diff introduces or materially expands:

- A view or cell that owns mutable model state instead of receiving an immutable snapshot plus action closures.
- Constraint creation inside repeated layout passes, or manual frame mutation that conflicts with active Auto Layout constraints.
- Full table, collection, sidebar, or outline reloads when a bounded diffable-data-source snapshot can express the update.
- Model mutation from `layout()`, `layoutSubviews()`, cell configuration, drawing, or measurement callbacks.
- View-controller lifecycle split across multiple coordinators without one explicit owner for containment, appearance transitions, and cancellation.

Allowed cases:

- Existing legacy state that the pull request only touches incidentally.
- Manual layout in a contained performance-sensitive view when ownership and invalidation are explicit.
- Full reloads for small, bounded collections when a diff adds complexity without measurable benefit.

cmux-specific emphasis:

- Large list and sidebar rows receive value snapshots and closures. Store references below reuse boundaries can refresh every row and create CPU spin loops.
- Lifecycle-time state writes belong in explicit callbacks, model observers, reload completions, or event handlers.

When reporting, identify the changed controller or view boundary and suggest the snapshot/action, containment, or diffable-data-source replacement.
