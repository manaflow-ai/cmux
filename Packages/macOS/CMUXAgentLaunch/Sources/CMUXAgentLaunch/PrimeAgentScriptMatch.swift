import Foundation

/// Recognizes a Prime Agent coding-agent entrypoint in a managed bundle layout.
///
/// Prime's launcher normally invokes a versioned bundle below the managed
/// `~/.prime/agent` directory (or a source checkout), so an arbitrary
/// `cli.js` path must not identify a process as Prime Agent.
public struct PrimeAgentScriptMatch: Sendable {
    /// Creates a stateless Prime Agent script matcher.
    public init() {}

    /// Returns whether `path` is a recognized Prime Agent entrypoint.
    ///
    /// Path separators are normalized before matching so process-table argv
    /// captured from a translated environment is treated consistently.
    ///
    /// - Parameter path: A process-table argument that may name the entrypoint.
    /// - Returns: `true` only for a known entrypoint in a managed coding-agent layout.
    public func matches(_ path: String) -> Bool {
        let normalized = path
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
            .lowercased()
        let basename = (normalized as NSString).lastPathComponent
        guard Self.knownEntrypoints.contains(basename),
              Self.hasManagedPrimeRoot(normalized),
              Self.hasCodingAgentBundle(normalized) else {
            return false
        }
        return true
    }

    private static let knownEntrypoints: Set<String> = [
        "cli.js",
        "cli.ts",
        "index.js",
        "index.ts",
    ]

    private static func hasManagedPrimeRoot(_ path: String) -> Bool {
        path.contains("/.prime/agent/")
            || path.contains("/prime-agent/packages/")
            || path.contains("/node_modules/prime-agent/")
            || path.contains("/@earendil-works/pi-coding-agent/")
    }

    private static func hasCodingAgentBundle(_ path: String) -> Bool {
        path.contains("/packages/coding-agent/dist/bundle/")
            || path.contains("/packages/coding-agent/src/")
            || path.contains("/node_modules/prime-agent/dist/bundle/")
            || path.contains("/@earendil-works/pi-coding-agent/dist/")
            || path.contains("/@earendil-works/pi-coding-agent/src/")
    }
}
