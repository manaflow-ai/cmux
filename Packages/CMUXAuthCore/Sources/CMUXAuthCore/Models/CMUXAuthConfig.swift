import Foundation

/// The Stack Auth project credentials an app build signs in against.
public struct CMUXAuthConfig: Equatable, Sendable {
    /// The Stack Auth project id.
    public let projectId: String
    /// The Stack Auth publishable client key for that project.
    public let publishableClientKey: String

    /// Creates a configuration from already-resolved credentials.
    public init(projectId: String, publishableClientKey: String) {
        self.projectId = projectId
        self.publishableClientKey = publishableClientKey
    }

    /// Resolve the configuration for an environment, applying string
    /// overrides (e.g. parsed from a bundled `LocalConfig.plist`).
    ///
    /// Recognized override keys: `STACK_PROJECT_ID_DEV/PROD` and
    /// `STACK_PUBLISHABLE_CLIENT_KEY_DEV/PROD`. The per-environment defaults
    /// are injected by the caller so this package carries no baked-in project
    /// identifiers.
    /// - Parameters:
    ///   - environment: The build environment, decided by the composition root.
    ///   - overrides: Optional string overrides; missing keys fall back to the
    ///     injected defaults.
    ///   - developmentProjectId: Default project id for ``CMUXAuthEnvironment/development``.
    ///   - productionProjectId: Default project id for ``CMUXAuthEnvironment/production``.
    ///   - developmentPublishableClientKey: Default key for development.
    ///   - productionPublishableClientKey: Default key for production.
    public init(
        environment: CMUXAuthEnvironment,
        overrides: [String: String] = [:],
        developmentProjectId: String,
        productionProjectId: String,
        developmentPublishableClientKey: String,
        productionPublishableClientKey: String
    ) {
        switch environment {
        case .development:
            self.init(
                projectId: overrides["STACK_PROJECT_ID_DEV"] ?? developmentProjectId,
                publishableClientKey: overrides["STACK_PUBLISHABLE_CLIENT_KEY_DEV"] ?? developmentPublishableClientKey
            )
        case .production:
            self.init(
                projectId: overrides["STACK_PROJECT_ID_PROD"] ?? productionProjectId,
                publishableClientKey: overrides["STACK_PUBLISHABLE_CLIENT_KEY_PROD"] ?? productionPublishableClientKey
            )
        }
    }
}
