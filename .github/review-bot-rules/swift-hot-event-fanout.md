# Swift Hot Event Fanout

Flag Swift hot-path changes that widen a small event into broad work.

Apply this rule to production Swift callbacks, publishers, observers, socket handlers, SwiftUI row updates, terminal title changes, filesystem/process notifications, and other paths that can fire while the user is typing, agents are streaming, terminals are changing titles, or sidebar/list rows are being reconciled.

## Fail

- A per-surface, per-pane, per-session, or per-row event calls a workspace-wide or app-wide sweep when the event already carries the id needed to update one owner.
- A hot `@MainActor` callback performs or schedules an unbounded filesystem scan, transcript lookup, process walk, sort/filter, or full collection traversal without an explicit per-key coalescer, in-flight dedupe, cancellation, and bounded retry policy.
- A SwiftUI `LazyVStack`, `LazyHStack`, `List`, or large `ForEach` row receives parent-computed values derived from volatile global state when only the affected row(s) should observe the change. Examples include selection, hover, focus, progress, title, or notification state that causes all rows to be re-instantiated or reconciled for a one-row/two-row change.
- A hot event path reuses a cold refresh/listing function without preserving event scope. For example, a title-change observer for one terminal surface must not call a workspace adoption path that scans every terminal panel.

## Pass

- Cold refresh paths, explicit reload actions, and list endpoints that intentionally reconcile a full workspace or app snapshot and are not called from high-frequency event streams.
- Hot paths that route to a single owner by id, then coalesce, cancel, or dedupe expensive work by surface/session/workspace key.
- Lazy/list rows that receive immutable snapshots and closures, or subscribe row-locally to a global publisher with `removeDuplicates()` on the row's reduced value.
- Tiny fixed-size collections, or broad work with a documented bound and benchmark/profiling note showing it stays within the relevant UI or runtime budget.

## Report

When this rule fails, name the hot event source, the widened scope, the collection or subsystem being swept, and the expected scale. Suggest the smallest source-of-truth fix: preserve the event's id, route to the single owner, add a per-key coalescer/in-flight task, move heavy work off the main actor, or make row observation local and duplicate-filtered.
