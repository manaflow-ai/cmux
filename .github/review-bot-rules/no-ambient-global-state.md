# No Ambient Global State

Apply this rule to production Swift code, especially package source under `**/Sources/**`. It covers global free functions, global mutable state, caseless-enum/struct namespaces of static helpers, and new singletons. This complements `swift-actor-isolation.md` (isolation) and `swift-architectural-rethink.md` (symptom patches); this rule is specifically about ownership: state and behavior must live on an owning type that can be constructed, injected, and tested, not in ambient global scope.

The lessons are from a browser sign-in flow that shipped top-level public helper functions plus a stub class holding a global `resumeOnceFlag`, and from repeated review pushback on detector/decoder/config types that exist only as a bag of `static func`s used as a namespace, and on a drag-state registry hung off the singleton app delegate.

## Fail

- A new top-level (file-scope, no enclosing type) `func` used as API, especially `public`/`internal` free functions that callers reach globally instead of methods on an owning type.
- A new top-level mutable `var` (global mutable state) or a stub/empty class/struct that exists only to hold a global flag, counter, or once-token (for example a `resumeOnceFlag`).
- A caseless `enum` or empty `struct` used purely as a namespace of `static func`/`static let` members, or a type whose API is mostly `static func`s, when the behavior should be instance methods on a constructable, injectable type.
- A new singleton (`static let shared`/`static let standard`/`static let default`, or new global state hung off the app delegate) introduced for runtime state that should be owned by a scoped type and injected at the app seam.
- Widening a helper to `public`/`internal` global scope to make it reachable, when the right shape is a method on the type that owns the data.

## Pass

- Free functions that are genuinely module-level pure utilities with no shared mutable state, kept `private`/`fileprivate` at file scope (the preferred shape for small local helpers over a private-static helper bag).
- `static let` constants, `enum` cases, and protocol/extension conformances that are not a static-helper namespace.
- An existing singleton or static-namespace type only moved or touched incidentally, when the PR does not add new ambient global surface.
- A platform/bridge boundary (AppKit, C interop, `@main` entry) that legitimately requires top-level declarations, with the reason stated.

## Report

When this rule fails, name the exact file and line, name the ambient global surface (free function, global var, static-only namespace, or new singleton), and propose the owning type the state/behavior should move onto and where it should be constructed and injected.
