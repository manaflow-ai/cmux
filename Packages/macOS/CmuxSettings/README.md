# CmuxSettings

Strongly-typed, migratable settings storage for cmux. Depends only on
Foundation and `CmuxFileWatch` (for config-file reload watching). Modern
Swift 6 throughout: actors, `AsyncStream`, value-typed keys, dependency
injection. No locks, no KVO, no `@Published`.

Settings live in one of two stores:

- **`UserDefaultsSettingsStore`** — wraps `UserDefaults`. User-toggled
  preferences that the Settings UI writes.
- **`JSONConfigStore`** — wraps `~/.config/cmux/cmux.json`. Structured config
  authored by users (hooks, shortcut bindings) or MDM profiles.

Each setting is declared once on a `SettingCatalog` instance with the typed
backend it belongs to. The two stores accept only their respective flavor
of key — wrong-store mismatches are compile errors, not runtime traps.

## On-disk layout

- **UserDefaults** persists under the normal Apple-managed plist for the
  process's `Bundle.main.bundleIdentifier`, viewable with
  `defaults read <bundle-id>`.
- **JSON config** lives at `~/.config/cmux/cmux.json` by default
  (`CmuxConfigLocation().userConfigFile`). The store creates the file (and
  parent directory) on first write. File is missing on first launch, in
  which case every read returns the key's default value.

A populated cmux.json looks like this — pretty-printed, sorted keys, JSONC
comments tolerated on read but stripped on write:

```jsonc
{
  // Automation socket configuration.
  "automation": {
    "socketPassword": "hunter2"
  }
}
```

The dotted-id of each JSON-backed key is the JSON path; e.g.
`SettingCatalog.automation.socketPassword.id == "automation.socketPassword"`
addresses `root["automation"]["socketPassword"]` above.

## Quick start

```swift
import CmuxSettings

// 1. Construct the catalog at app startup.
let catalog = SettingCatalog()

// 2. Construct each store (DI; no shared singletons).
let userDefaultsStore = UserDefaultsSettingsStore(
    defaults: .standard,
    migrating: catalog.all
)
let jsonConfigStore = JSONConfigStore(
    fileURL: CmuxConfigLocation().userConfigFile
)

// 3. Read / write.
let mode = await userDefaultsStore.value(for: catalog.app.appearance)
await userDefaultsStore.set(.dark, for: catalog.app.appearance)

try await jsonConfigStore.set(
    "hunter2",
    for: catalog.automation.socketPassword
)

// 4. Observe changes. Returns AsyncStream that yields the current value
// first, then every later change.
for await newMode in userDefaultsStore.values(for: catalog.app.appearance) {
    applyAppearance(newMode)
}
```

## End-to-end example

A runnable snippet that exercises read, write, and external-edit
observation through a temp directory — useful as a copy-paste-and-run
sanity check or as a starting point for integration tests:

```swift
import CmuxSettings
import Foundation

// Scope the JSON store to a temp file so this example is hermetic.
let tempDir = FileManager.default.temporaryDirectory
    .appending(path: "cmux-readme-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
let fileURL = tempDir.appending(path: "cmux.json")

let catalog = SettingCatalog()
let json = JSONConfigStore(fileURL: fileURL)

// Initially missing → default.
let initial = await json.value(for: catalog.automation.socketPassword)
assert(initial == "")

// Write → file is created with the parent directory.
try await json.set("hunter2", for: catalog.automation.socketPassword)
assert(await json.value(for: catalog.automation.socketPassword) == "hunter2")

// Observe → react to external edits (simulated here).
let task = Task {
    for await value in json.values(for: catalog.automation.socketPassword) {
        print("password is now:", value)
    }
}

try Data(#"{"automation":{"socketPassword":"rotated"}}"#.utf8)
    .write(to: fileURL, options: .atomic)

// ... do other work; cancel when done observing.
// task.cancel()
```

## Handling errors

`UserDefaultsSettingsStore` reads and writes never throw (UserDefaults is
fire-and-forget). `JSONConfigStore.set(_:for:)` and `reset(_:)` are
`throws`: they propagate filesystem errors (permission denied, disk full).
The store's in-memory cache is **only** updated after the disk write
succeeds, so a failed write leaves subsequent reads consistent with what
is actually on disk.

## Adding a new setting

1. Pick the catalog section under `Sources/CmuxSettings/Keys/` (e.g.
   `AppCatalogSection.swift`). Add a new stored property.
2. Choose the backend:
   - `DefaultsKey<Value>` for UserDefaults-backed settings.
   - `JSONKey<Value>` for JSON-config-backed settings.
3. Pick the value type. Common cases work out of the box:
   - Primitives (`Bool`, `Int`, `Double`, `String`, `Data`, `URL`) — done.
   - Arrays / `[String: …]` of conforming elements — done.
   - `RawRepresentable` enums whose raw value is `SettingCodable` — done.
   - Custom struct — implement `SettingCodable` (4 methods, one for each
     decode/encode + backend pair).
4. `catalog.all` updates automatically via `Mirror` reflection over the
   catalog's stored properties; no parallel list to maintain.

## Adding a whole new section

1. Create `Sources/CmuxSettings/Keys/FooCatalogSection.swift`:
   ```swift
   public struct FooCatalogSection: SettingCatalogSection {
       public let bar = DefaultsKey<Bool>(
           id: "foo.bar",
           defaultValue: false,
           userDefaultsKey: "fooBar"
       )
       public init() {}
   }
   ```
2. Add `public let foo = FooCatalogSection()` to `SettingCatalog`.

Reflection picks it up recursively; `catalog.all` includes every leaf.

## Architecture

- **`SettingCatalog`** — root value-typed registry. Composed of
  `SettingCatalogSection` sub-structs grouped by dotted-id prefix.
- **`DefaultsKey<V>` / `JSONKey<V>`** — strongly-typed setting handles. Each
  store accepts only its flavor.
- **`AnySettingKey`** — type-erased view. Used for catalog enumeration
  (`catalog.all`) and legacy-key migration that's still
  type-safe via a captured closure.
- **`UserDefaultsSettingsStore`** — `actor`. Async reads/writes/observe.
  Observation uses `NotificationCenter.default.notifications(named:)`.
- **`JSONConfigStore`** — `actor`. Async reads/writes/observe. Owns one
  `CmuxFileWatch.FileWatcher` and fans out file-change events to per-subscriber
  bounded signal streams (no `N × parse` work under burst changes). File
  watching itself lives in the `CmuxFileWatch` package.

## Testing

Tests construct `DefaultsKey` / `JSONKey` directly with a temp-suite
`UserDefaults` or a temp-dir file URL. The catalog isn't a test fixture; it
is the production registry. See `Tests/CmuxSettingsTests/` for patterns.

### Keyboard-shortcut `when` clauses

`ShortcutWhenClause` parses a VS Code-style predicate over context keys and
evaluates it against a `ShortcutContext` value — no app, AppKit, or filesystem
needed. Build a context by hand and assert evaluation:

```swift
var context = ShortcutContext()
context.setBool(ShortcutContextKnownKey.workspaceCanvasLayout.rawValue, true)
context.setString(ShortcutContextKnownKey.sidebarMode.rawValue, "find")
context.setInt(ShortcutContextKnownKey.paneCount.rawValue, 2)

let clause = ShortcutWhenClause.parse("workspaceCanvasLayout && paneCount > 1")
#expect(clause?.evaluate(context) == true)
```

`ShortcutWhenClause.canCoexist(_:_:)` decides whether two clauses can both hold
(conflict detection); it is exact for the focus atoms and conservative for typed
comparisons. See `Tests/CmuxSettingsTests/ShortcutWhenClauseTests.swift`.

## Concurrency

The cmux repo enforces a strict modern-concurrency policy
(see the cmux `CLAUDE.md` "Modern Swift concurrency" section): no locks,
no manual KVO, no `@Published`/`ObservableObject`, no `DispatchQueue.main.async`,
no completion-handler APIs in new code. This package adheres to that policy
end-to-end and builds clean under
`-strict-concurrency=complete -warnings-as-errors`.
