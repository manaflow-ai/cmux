public import Foundation
public import CmuxTerminalCore
internal import Darwin

/// Configures the process environment libghostty and spawned shells inherit
/// before any terminal surface is created.
///
/// This runs once at app launch, from the composition root, before the tab
/// manager (and therefore any surface spawn) is constructed. It resolves and
/// exports `GHOSTTY_RESOURCES_DIR`, points `TERMINFO` at the bundled terminfo,
/// seeds the managed terminal identity (`TERM`, `COLORTERM`, `TERM_PROGRAM`)
/// when the host has not already set it, and prepends the resources-derived
/// data and man directories onto `XDG_DATA_DIRS` and `MANPATH`.
///
/// The terminal-identity values are sourced from ``TerminalSurface`` so the
/// launch-time defaults stay co-located with the per-spawn managed identity.
///
/// Every outside-world seam is injected: the resources resolver carries its
/// own injected `FileManager`, the bundle resource URL is supplied by the
/// caller, and environment reads/writes go through closures so tests can drive
/// the configurer against a scoped environment without mutating the real
/// process. Production wires the resolver to `FileManager.default`, the bundle
/// URL to `Bundle.main.resourceURL`, and the environment closures to
/// `getenv`/`setenv`.
public struct GhosttyStartupEnvironment: Sendable {
    private let resourcesResolver: GhosttyResourcesDirectoryResolver
    private let fileExists: @Sendable (String) -> Bool
    private let bundleResourceURL: URL?
    private let getEnvironmentValue: @Sendable (String) -> String?
    private let setEnvironmentValue: @Sendable (String, String) -> Void

    /// Creates a configurer wired to the real process environment.
    ///
    /// - Parameters:
    ///   - resourcesResolver: Resolves `GHOSTTY_RESOURCES_DIR` from the
    ///     inherited value and this app's bundle.
    ///   - bundleResourceURL: This app's `Bundle.main.resourceURL`.
    ///   - fileExists: The file-existence capability used to probe the bundled
    ///     terminfo; defaults to the real file system. A `@Sendable` closure
    ///     rather than a stored `FileManager`, which is non-`Sendable`.
    ///   - getEnvironmentValue: Reads a process environment variable; defaults
    ///     to `getenv`.
    ///   - setEnvironmentValue: Writes (overwriting) a process environment
    ///     variable; defaults to `setenv` with overwrite enabled.
    public init(
        resourcesResolver: GhosttyResourcesDirectoryResolver = GhosttyResourcesDirectoryResolver(),
        bundleResourceURL: URL?,
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        getEnvironmentValue: @escaping @Sendable (String) -> String? = { key in
            getenv(key).flatMap { String(cString: $0) }
        },
        setEnvironmentValue: @escaping @Sendable (String, String) -> Void = { key, value in
            setenv(key, value, 1)
        }
    ) {
        self.resourcesResolver = resourcesResolver
        self.bundleResourceURL = bundleResourceURL
        self.fileExists = fileExists
        self.getEnvironmentValue = getEnvironmentValue
        self.setEnvironmentValue = setEnvironmentValue
    }

    /// Applies the managed Ghostty startup environment to the process.
    ///
    /// Must be called once, before any terminal surface is spawned.
    public func configure() {
        let currentResourcesDir = getEnvironmentValue("GHOSTTY_RESOURCES_DIR")
        if let resolvedResourcesDir = resourcesResolver.resolve(
            currentValue: currentResourcesDir,
            bundleResourceURL: bundleResourceURL
        ) {
            setEnvironmentValue("GHOSTTY_RESOURCES_DIR", resolvedResourcesDir)
        }

        if getEnvironmentValue("TERMINFO") == nil,
           let terminfoURL = bundleResourceURL?.appendingPathComponent("terminfo"),
           fileExists(terminfoURL.path) {
            setEnvironmentValue("TERMINFO", terminfoURL.path)
        }

        if getEnvironmentValue("TERM") == nil {
            setEnvironmentValue("TERM", TerminalSurface.managedTerminalType)
        }

        if getEnvironmentValue("COLORTERM") == nil {
            setEnvironmentValue("COLORTERM", TerminalSurface.managedColorTerm)
        }

        if getEnvironmentValue("TERM_PROGRAM") == nil {
            setEnvironmentValue("TERM_PROGRAM", TerminalSurface.managedTerminalProgram)
        }

        if let resourcesDir = getEnvironmentValue("GHOSTTY_RESOURCES_DIR") {
            let resourcesURL = URL(fileURLWithPath: resourcesDir)
            let resourcesParent = resourcesURL.deletingLastPathComponent()
            let dataDir = resourcesParent.path
            let manDir = resourcesParent.appendingPathComponent("man").path

            prependEnvPathIfMissing(
                "XDG_DATA_DIRS",
                path: dataDir,
                defaultValue: "/usr/local/share:/usr/share"
            )
            prependEnvPathIfMissing("MANPATH", path: manDir)
        }
    }

    private func prependEnvPathIfMissing(_ key: String, path: String, defaultValue: String? = nil) {
        if path.isEmpty { return }
        var current = getEnvironmentValue(key) ?? ""
        if current.isEmpty, let defaultValue {
            current = defaultValue
        }
        if current.split(separator: ":").contains(Substring(path)) {
            return
        }
        let updated = current.isEmpty ? path : "\(path):\(current)"
        setEnvironmentValue(key, updated)
    }
}
