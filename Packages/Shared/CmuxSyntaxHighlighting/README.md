# CmuxSyntaxHighlighting

Leaf package for token-coloring source text. File Preview (and later other native code views) consume it. Editor chrome — gutters, current-line, indent guides — stays in the app target.

## Test instantiation

```swift
let catalog = LanguageCatalog()
let language = catalog.language(forExtension: "json")

let policy = HighlightPolicy()
guard policy.shouldHighlight(content: source, language: language) else { return }

let engine = HighlightrSyntaxEngine(policy: policy)
let highlighted = await engine.highlight(text: source, language: language, theme: .dark)
```

No filesystem, `UserDefaults`, or app launch is required. `swift test` in this directory is the package gate.
