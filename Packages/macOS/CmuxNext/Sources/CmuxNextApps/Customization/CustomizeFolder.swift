import CmuxNextCompat
public import Foundation

/// The user's customization folder, the package of the `local/customize` app.
///
/// It resolves the path the daemon watches (`customize_dir` in cmux-tui-core): `$CMUX_CUSTOMIZE_DIR`,
/// else `$XDG_CONFIG_HOME/cmux/customize`, else `~/.config/cmux/customize`. The daemon installs the
/// app by itself the first time the folder holds a manifest, so writing the starter is all it takes
/// to make one.
///
/// ```swift
/// let folder = CustomizeFolder(url: temporaryDirectory)
/// let wrote = try await folder.writeStarter()
/// ```
public nonisolated struct CustomizeFolder: Sendable, Hashable {
    /// The folder.
    public let url: URL

    /// A folder at `url` (tests pass a temporary directory).
    public init(url: URL) {
        self.url = url
    }

    /// The folder the daemon reads for `environment`; nil when neither a customize, config nor home
    /// directory is set.
    ///
    /// - Parameter environment: The process environment (`ProcessInfo.processInfo.environment`).
    public init?(environment: [String: String]) {
        func value(_ name: String) -> String? { environment[name].flatMap { $0.isEmpty ? nil : $0 } }
        if let dir = value("CMUX_CUSTOMIZE_DIR") {
            url = URL(filePath: dir, directoryHint: .isDirectory)
            return
        }
        guard let config = value("XDG_CONFIG_HOME").map({ URL(filePath: $0, directoryHint: .isDirectory) })
            ?? value("HOME").map({ URL(filePath: $0, directoryHint: .isDirectory).appending(path: ".config") }) else { return nil }
        url = config.appending(path: "cmux").appending(path: "customize")
    }

    /// The app's manifest, `cmux-app.json`.
    public var manifestURL: URL { url.appending(path: "cmux-app.json") }

    /// The script the starter writes, `main.js`.
    public var scriptURL: URL { url.appending(path: "main.js") }

    /// Writes the starter view (one sidebar section built from the kit) when the folder has no
    /// manifest yet, off the main actor; an existing manifest or script is never overwritten.
    ///
    /// - Returns: Whether the starter was written; false when the folder already has a manifest
    ///   (one the supervisor did not install has an error to fix, not a starter to add).
    /// - Throws: The file system's error when the folder or a file cannot be written.
    @discardableResult
    @concurrent public func writeStarter() async throws -> Bool {
        let files = FileManager.checked
        guard !files.fileExists(atPath: manifestURL.path(percentEncoded: false)) else { return false }
        try files.createDirectory(at: url, withIntermediateDirectories: true)
        if !files.fileExists(atPath: scriptURL.path(percentEncoded: false)) {
            try Data(starterScript.utf8).blockingWrite(to: scriptURL, options: .withoutOverwriting)
        }
        try Data(starterManifest.utf8).blockingWrite(to: manifestURL, options: .withoutOverwriting)
        return true
    }
}

// The starter is skills/cmux-customization/templates/starter: the user's own file from then on.
nonisolated private let starterManifest = """
{
  "$schema": "https://cmux.dev/schemas/cmux-app/2.json",
  "manifestVersion": 2,
  "id": "local/customize",
  "name": "My views",
  "version": "1.0.0",
  "description": "A starting point: one sidebar section built from the kit.",
  "engines": { "cmux": "^2.0" },
  "runtime": { "main": "main.js" },
  "implements": {
    "cmux.section/1": {
      "export": "renderSection",
      "title": "My section",
      "symbol": "sparkles",
      "options": { "defaultRegion": "top" }
    }
  }
}

"""

nonisolated private let starterScript = """
// The customize app's script: a classic script, not a module (no import or export).
// The scene globals (VStack, Panel, Row, Button, Toggle, Text, signal, computed, cmux, ...)
// are already defined. cmux reloads this file every time it is saved.
// Show or hide this sidebar with Toggle Custom Sidebar (Cmd+Shift+P) or Ctrl+Opt+Cmd+B.

// State lives in signals; a view that reads one redraws when it changes.
const [count, setCount] = signal(0)

// One render function per implementation in cmux-app.json (its "export").
function renderSection() {
  return VStack([
    Panel({ title: "Hello" }, [
      Text(() => `Clicked ${count()} times`).font("headline"),
      HStack([
        Button("Click", () => setCount((n) => n + 1)),
        Spacer(),
        Button("Say hi", () => cmux.toast({ title: "Hi from my section", tone: "success" }))
      ])
    ]),
    Row({ title: "Edit ~/.config/cmux/customize/main.js", symbol: "pencil", tint: cmux.theme.text.secondary })
  ])
}

// Hand every render function to cmux, once, in one object.
globalThis.__cmuxAppExports = { renderSection }

"""
