# CmuxSyntaxHighlighting

Leaf package for token-coloring source text. File Preview (and later other native code views) consume it. Editor chrome — gutters, current-line, indent guides — stays in the app target.

Token colors are the cmux product palette (`TokenPalette.cmuxDark` / `.cmuxLight`): electric `#0091FF` / `#006DC1` keywords on the published neutrals, not Highlightr's stock Xcode magenta. Highlightr still tokenizes with bundled `xcode` / `xcode-dark` CSS; `HighlightColorRemapper` paints the product colors.

Languages missing from Highlightr's bundled highlight.js build are added as `HighlightGrammar` values (HCL for Terraform/OpenTofu today). `HighlightrThemeAdapter` registers them with Highlightr's highlight.js instance when it starts; a grammar that fails to register leaves its files uncolored rather than letting Highlightr auto-detect a language.

## Test instantiation

```swift
let catalog = LanguageCatalog()
let language = catalog.language(forExtension: "json")

let policy = HighlightPolicy()
guard policy.shouldHighlight(content: source, language: language) else { return }

let engine = HighlightrSyntaxEngine(policy: policy)
let highlighted = await engine.highlight(text: source, language: language, theme: .dark)
// Tokens are remapped from Highlightr's xcode-dark CSS onto TokenPalette.cmuxDark.
```

No filesystem, `UserDefaults`, or app launch is required. `swift test` in this directory is the package gate.
