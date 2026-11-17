# CmuxTheme

Chrome colors derived from a terminal theme, shared by the macOS and iOS apps.
`ThemeInput` holds a theme's colors, and `ThemeTokens.derive(from:)` turns them
into every surface, fill and text color, with each text tier holding its WCAG
contrast. The package is pure values: no AppKit, UIKit or SwiftUI. Each app adds
its own color conversions (`CmuxNextDesign` adds `nsColor` and `cgColor`).

## Testing

Everything is a value, so a test builds an input and checks the tokens. The
tests live in `CmuxNextDesignTests`, which CI's cmux-next lane runs:

```swift
import CmuxTheme
import Testing

@Test func defaultTextIsReadable() {
    let tokens = ThemeTokens.derive(from: .ghosttyDefault)
    #expect(tokens.textPrimary.contrast(with: tokens.contentBackground) >= 4.5)
}
```
