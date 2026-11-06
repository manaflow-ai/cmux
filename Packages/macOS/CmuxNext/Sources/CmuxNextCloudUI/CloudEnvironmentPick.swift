public import Foundation

/// `cmux cloud new-machine --environment ID|NAME` (`cmux cloud start-chat --environment` runs it): the word that
/// names one of the team's Cloud environments, read as its id (cloud-environments-DESIGN.md).
extension CloudWorkspaceSetupWizard.EnvironmentOption {
    /// A word that names none of the team's environments, or no word at all.
    public nonisolated struct Unknown: LocalizedError, CustomStringConvertible, Equatable {
        public init() {}
        public var errorDescription: String? { CloudEnvironmentStrings().unknownWord }
        public var description: String { CloudEnvironmentStrings().unknownWord }
    }

    /// `--environment`'s word, trimmed; ``Unknown`` for an empty one.
    public nonisolated static func word(_ text: String) throws -> String {
        text
    }

    /// The id `wanted` names: an `env_…` id as given, else the id of the environment in `options` (the app's
    /// `cloud.environment.list`) with that name, exactly or in any case; ``Unknown`` for a name none has.
    public nonisolated static func id(for wanted: String, in options: [Self]) throws -> String {
        wanted
    }
}
