import Foundation

/// Resolves the hook state directory used by short-lived CLI hook writers.
///
/// Existing terminals may predate `CMUX_AGENT_HOOK_STATE_DIR`, but they still
/// carry `CMUX_BUNDLE_ID`. Using that inherited identity keeps their later hook
/// events in the same bundle scope as newly created terminals.
public struct AgentHookStateWriterLocation: Sendable, Equatable {
    /// The directory where the hook process should write agent session stores.
    public let directoryURL: URL

    /// Resolves a writer directory from inherited terminal and executable identity.
    public init(
        environment: [String: String],
        applicationSupportDirectory: URL?,
        containingBundleIdentifier: String?,
        legacyHomeDirectory: URL
    ) {
        let inheritedBundleIdentifier = environment["CMUX_BUNDLE_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bundleIdentifier = inheritedBundleIdentifier?.isEmpty == false
            ? inheritedBundleIdentifier
            : containingBundleIdentifier
        directoryURL = AgentHookStateLocation(
            environment: environment,
            applicationSupportDirectory: applicationSupportDirectory,
            bundleIdentifier: bundleIdentifier,
            legacyHomeDirectory: legacyHomeDirectory
        ).directoryURL
    }
}
