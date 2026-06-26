/// Directory-skip policy used when walking a project tree to index `@`-mention
/// file candidates.
///
/// Decides which directory names are excluded wholesale (for example
/// `node_modules`, `.build`, `.git`, `DerivedData`, `vendor`) and which
/// package-bundle path suffixes are excluded case-insensitively (for example
/// `.app`, `.xcodeproj`, `.framework`). The raw lists are also exposed so a
/// caller can translate them into the equivalent `ripgrep` glob arguments.
public struct IndexedDirectorySkipPolicy: Sendable {
    /// Directory names skipped wholesale during an indexed walk.
    public let skippedDirectoryNames: Set<String>

    /// Package-bundle path suffixes whose directories are skipped (matched
    /// case-insensitively against the lowercased directory name).
    public let skippedPackageDirectorySuffixes: [String]

    /// Creates a skip policy. The defaults match the cmux project-tree index rules.
    public init(
        skippedDirectoryNames: Set<String> = [
            ".build",
            ".git",
            ".next",
            ".swiftpm",
            ".vercel",
            "DerivedData",
            "Library",
            "node_modules",
            "Pods",
            "vendor"
        ],
        skippedPackageDirectorySuffixes: [String] = [
            ".app",
            ".appex",
            ".bundle",
            ".dSYM",
            ".framework",
            ".kext",
            ".mdimporter",
            ".plugin",
            ".prefPane",
            ".qlgenerator",
            ".rtfd",
            ".xcframework",
            ".xcodeproj",
            ".xcworkspace",
            ".playground"
        ]
    ) {
        self.skippedDirectoryNames = skippedDirectoryNames
        self.skippedPackageDirectorySuffixes = skippedPackageDirectorySuffixes
    }

    /// Returns `true` when a directory named `name` should be skipped during indexing.
    public func shouldSkip(_ name: String) -> Bool {
        if skippedDirectoryNames.contains(name) {
            return true
        }
        let normalizedName = name.lowercased()
        return skippedPackageDirectorySuffixes.contains { suffix in
            normalizedName.hasSuffix(suffix.lowercased())
        }
    }
}
