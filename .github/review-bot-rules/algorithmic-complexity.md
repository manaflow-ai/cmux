# Algorithmic Complexity

Apply this rule to production code that iterates over collections that can grow with user data, especially workspaces, panes, sessions, notifications, search results, files, browser profiles, VMs, processes, logs, and database rows.

## Fail

- A loop over a scalable collection that performs `first(where:)`, `firstIndex(where:)`, `contains(where:)`, `filter`, `map`, `sorted`, `Array.find`, `Array.some`, `Array.includes`, or another full scan over the same scalable collection for each item.
- Batch actions over workspace ids, pane ids, session ids, notification ids, file paths, VM ids, or process ids that rescan the full backing collection per target instead of using a `Set`, dictionary, index, grouped query, or one-pass plan.
- SwiftUI `body`, row rendering, typing, socket telemetry, notification, file-watcher, search, or process-sampling paths that rebuild, sort, or filter unbounded collections on every event without a cached snapshot or explicit size bound.
- Backend or persistence changes that fetch broad result sets and do per-row in-memory joins, filters, or lookups when the data store can perform the lookup, grouping, join, or pagination.
- An algorithm choice for a path expected to handle roughly 1000 workspaces, sessions, files, rows, or similar user-owned records without either a linear-time design or a benchmark/profiling note showing the slower shape is acceptable.

## Pass

- Tiny fixed-size collections such as modifier keys, a small static command list, a fixed palette, or a known handful of panes, when the bound is explicit from the code.
- Test-only scaffolding, fixtures, benchmark harnesses, and intentionally slow reference implementations used to validate a faster implementation.
- Existing inefficient code that the PR does not introduce, expand, or move into a hotter path.
- A nested scan with a documented upper bound and a benchmark or measurement attached to the PR showing it stays within the relevant UI, socket, or backend budget.
- Code that deliberately trades asymptotic complexity for simpler constant factors on small inputs, with the threshold or fallback path made explicit.

## Report

When this rule fails, name the exact file and line, identify the scalable collection and estimated complexity, state the expected scale (for workspaces use about 1000 on one Mac unless the code states a lower bound), and suggest the smallest source-of-truth fix such as a `Set`, dictionary, indexed lookup, single-pass reducer, database query, cache, or benchmark-backed threshold.
