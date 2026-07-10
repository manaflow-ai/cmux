import AppKit

/// Ghostty-related process environment bootstrap, extracted from
/// `cmuxApp.swift` (which is over the file-length hard cap and must not
/// grow). Called once from `cmuxApp.init` before any terminal surface
/// is created.
extension cmuxApp {
    static func configureGhosttyEnvironment() {
        let fileManager = FileManager.default
        let currentResourcesDir = getenv("GHOSTTY_RESOURCES_DIR").flatMap { String(cString: $0) }
        if let resolvedResourcesDir = resolvedGhosttyResourcesDirectory(
            currentValue: currentResourcesDir,
            bundleResourceURL: Bundle.main.resourceURL,
            fileManager: fileManager
        ) {
            setenv("GHOSTTY_RESOURCES_DIR", resolvedResourcesDir, 1)
        }

        if getenv("TERMINFO") == nil,
           let terminfoURL = Bundle.main.resourceURL?.appendingPathComponent("terminfo"),
           fileManager.fileExists(atPath: terminfoURL.path) {
            setenv("TERMINFO", terminfoURL.path, 1)
        }

        if getenv("TERM") == nil {
            setenv("TERM", TerminalSurface.managedTerminalType, 1)
        }

        if getenv("COLORTERM") == nil {
            setenv("COLORTERM", TerminalSurface.managedColorTerm, 1)
        }

        if getenv("TERM_PROGRAM") == nil {
            setenv("TERM_PROGRAM", TerminalSurface.managedTerminalProgram, 1)
        }

        if let resourcesDir = getenv("GHOSTTY_RESOURCES_DIR").flatMap({ String(cString: $0) }) {
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

    static func resolvedGhosttyResourcesDirectory(
        currentValue: String?,
        bundleResourceURL: URL?,
        ghosttyAppResources: String = "/Applications/Ghostty.app/Contents/Resources/ghostty",
        fileManager: FileManager = .default
    ) -> String? {
        let bundledGhosttyURL = bundleResourceURL?.appendingPathComponent("ghostty")
        // Tagged cmux builds may inherit GHOSTTY_RESOURCES_DIR from another running
        // cmux instance. Prefer this app's bundled resources when they are present.
        if let bundledGhosttyURL,
           fileManager.fileExists(atPath: bundledGhosttyURL.path),
           fileManager.fileExists(atPath: bundledGhosttyURL.appendingPathComponent("themes").path) {
            return bundledGhosttyURL.path
        }

        if let currentValue = currentValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !currentValue.isEmpty,
           fileManager.fileExists(atPath: currentValue) {
            return currentValue
        }

        if fileManager.fileExists(atPath: ghosttyAppResources) {
            return ghosttyAppResources
        }

        if let bundledGhosttyURL,
           fileManager.fileExists(atPath: bundledGhosttyURL.path) {
            return bundledGhosttyURL.path
        }

        return nil
    }

    private static func prependEnvPathIfMissing(_ key: String, path: String, defaultValue: String? = nil) {
        if path.isEmpty { return }
        var current = getenv(key).flatMap { String(cString: $0) } ?? ""
        if current.isEmpty, let defaultValue {
            current = defaultValue
        }
        if current.split(separator: ":").contains(Substring(path)) {
            return
        }
        let updated = current.isEmpty ? path : "\(path):\(current)"
        setenv(key, updated, 1)
    }
}
