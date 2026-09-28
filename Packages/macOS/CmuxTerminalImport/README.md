# CmuxTerminalImport

Reads another terminal's settings and maps them onto Ghostty config for `cmux import`.
Everything here is read-only and pure: it never writes files. The CLI prints the
resulting `GhosttyImportPlan` as a diff and writes cmux's own config and theme files.

- Parsers: iTerm2 and Terminal preferences (Terminal's `NSColor`/`NSFont` archives are
  decoded without AppKit), Alacritty TOML/YAML with `import`, Kitty with `include`,
  literal top-level WezTerm Lua assignments, and Warp theme YAML.
- `GhosttyImportMapper` turns `ImportedTerminalSettings` into a theme file, config
  settings and notes about what was skipped or approximated.
- `GhosttyConfigDiffer` compares settings with a config body and reports old and new values;
  the CLI writes through cmux's shared `CmuxGhosttyConfigSettingEditor`.

Tests use fixtures and inject every outside dependency:

```swift
let importer = TerminalImporter(
    homeDirectory: URL(fileURLWithPath: "/Users/test"),
    environment: [:],
    preferences: StubPreferences(domains: ["com.googlecode.iterm2": fixtureURL]),
    files: DiskTerminalConfigFileReader()
)
let plan = GhosttyImportMapper(fontResolver: StubFontResolver())
    .plan(for: try importer.load(.iTerm2), themeDirectory: themesURL)
```

Run `swift test --package-path Packages/macOS/CmuxTerminalImport`.
