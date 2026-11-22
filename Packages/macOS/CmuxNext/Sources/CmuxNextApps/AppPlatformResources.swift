public import Foundation

/// Files synced from `cmux-tui/crates/cmux-app-host` and `samples/apps` by
/// `scripts/cmux-next/sync-app-runtime.sh` (never edit the copies).
public nonisolated enum AppPlatformResources {
    /// `Resources/AppPlatform` inside the module bundle.
    public static var root: URL {
        Bundle.module.resourceURL?.appending(path: "AppPlatform", directoryHint: .isDirectory)
            ?? Bundle.module.bundleURL.appending(path: "AppPlatform", directoryHint: .isDirectory)
    }

    /// The engine-neutral runtime (`dist/cmux-app-runtime.js`).
    public static var runtimeScript: URL { root.appending(path: "runtime/cmux-app-runtime.js") }
    /// `generated/scopes.json`: op name -> scope and class.
    public static var scopesFile: URL { root.appending(path: "scopes.json") }
    /// `schema/v2/scope-classes.json`: the risk class of every scope, shared
    /// with the Rust validator (`cmux-app-manifest`).
    public static var scopeClassesFile: URL { root.appending(path: "scope-classes.json") }
    public static var schemaFile: URL { root.appending(path: "schema/cmux-app.schema.json") }
    /// `schema/fixtures/{valid,invalid}` shared with the TypeScript validator.
    public static var fixtures: URL { root.appending(path: "schema/fixtures", directoryHint: .isDirectory) }
    /// The built first-party sample apps, one directory per app.
    public static var samples: URL { root.appending(path: "samples", directoryHint: .isDirectory) }
    /// First-party apps shipped inside cmux (`first-party-apps/<name>` with a BUNDLED marker).
    public static var firstParty: URL { root.appending(path: "first-party", directoryHint: .isDirectory) }
}
