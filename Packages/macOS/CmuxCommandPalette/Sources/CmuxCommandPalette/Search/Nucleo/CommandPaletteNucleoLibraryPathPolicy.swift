struct CommandPaletteNucleoLibraryPathPolicy: Sendable {
    let environmentPath: String?
    let bundledLibraryPath: String?
    let runtimeOwnership: String?
    let debugBuild: Bool

    var permitsDeveloperPaths: Bool {
        debugBuild && runtimeOwnership != "backend-only"
    }

    var prioritizedLibraryPaths: [String] {
        var paths: [String] = []
        if permitsDeveloperPaths,
           let environmentPath,
           !environmentPath.isEmpty {
            paths.append(environmentPath)
        }
        if let bundledLibraryPath, !bundledLibraryPath.isEmpty {
            paths.append(bundledLibraryPath)
        }
        return paths
    }
}
