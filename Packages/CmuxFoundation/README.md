# CmuxFoundation

Shared low-level primitives for cmux with no internal package dependencies. This is the
bottom of the package dependency graph: encoding/text helpers, value types, and other
cross-cutting utilities that several domains need, with nothing in here depending on AppKit,
SwiftUI, or another cmux package.

It exists as the leaf every other package and the app target can depend on without creating
a cycle. Keep it dependency-free.

Foundation helpers are exposed as extensions on existing types rather than free functions,
so call sites read naturally (`value.javaScriptStringLiteral`, not `f(value)`).

## Contents

- `String.javaScriptStringLiteral` — the string encoded as a quoted JavaScript string literal.
- `SSHAgentSocketResolver` — OpenSSH option parsing and SSH agent socket path normalization.

## Usage

```swift
import CmuxFoundation

let literal = userText?.javaScriptStringLiteral ?? "null"
webView.evaluateJavaScript("setValue(\(literal))")
```

## Testing

Everything here is a pure value transform, so tests need no app, no AppKit, and no filesystem:

```swift
import Testing
import CmuxFoundation

@Test func plainStringIsQuoted() {
    #expect("hello".javaScriptStringLiteral == "\"hello\"")
}
```
