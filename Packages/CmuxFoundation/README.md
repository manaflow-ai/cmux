# CmuxFoundation

Shared low-level primitives for cmux with no internal package dependencies. This is the
bottom of the package dependency graph: encoding/text helpers, value types, and other
cross-cutting utilities that several domains need and nothing in here depends on AppKit,
SwiftUI, or another cmux package.

It exists as the leaf every other package and the app target can depend on without creating
a cycle. Keep it dependency-free.

## Contents

- `cmuxJavaScriptStringLiteral(_:)` — encode a string as a quoted JavaScript string literal.

## Usage

```swift
import CmuxFoundation

let literal = cmuxJavaScriptStringLiteral(userText) ?? "null"
webView.evaluateJavaScript("setValue(\(literal))")
```

## Testing

Everything here is a pure value transform, so tests need no app, no AppKit, and no filesystem:

```swift
import Testing
import CmuxFoundation

@Test func plainStringIsQuoted() {
    #expect(cmuxJavaScriptStringLiteral("hello") == "\"hello\"")
}
```
