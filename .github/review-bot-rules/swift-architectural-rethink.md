# Swift Architectural Rethink

Apply the `swift-guidance` rules and the `rethink-architecturally` bar to Swift changes. Flag fixes that patch symptoms while leaving the bad state representable.

Report a failure when the diff introduces or materially expands:

- Timing or blocking repair paths (`DispatchQueue.main.async`, `asyncAfter`, `Task.sleep`, polling, semaphores, groups, locks, or notification waits) used to paper over lifecycle, focus, rendering, socket, terminal, or shared-state races.
- A new mutable flag, cache, singleton, observer, or side channel that creates another owner for state already owned by a model, actor, store, view coordinator, or persistence layer.
- The same behavior wired separately through multiple surfaces instead of one shared action path.
- SwiftUI or AppKit bridge code where UI lifecycle is split across multiple MainActor owners instead of one explicit owner with value snapshots and action closures.
- A fix that catches one repro but does not name the invariant, source of truth, or state transition that makes the whole class impossible.

Allowed cases:

- Small local correctness fixes where the owner and invariant remain clear.
- Required platform callback or bridge code with a documented reason and no extra timing dependency.
- Test-only synchronization or sleeps.
- Existing architectural debt that the PR does not introduce or worsen.

When reporting, include one highest-impact finding only. Explain the symptom, structural root cause, class of bugs, the single source of truth that should own the behavior, and the first migration cut that would prove the architecture.
