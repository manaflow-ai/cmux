public import CmuxNextCloud
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

    /// The team's environments could not be read (`cloud.environment.list` failed), so a name names none yet.
    public nonisolated struct ListUnread: LocalizedError, CustomStringConvertible, Equatable {
        public init() {}
        public var errorDescription: String? { CloudEnvironmentStrings().listUnread }
        public var description: String { CloudEnvironmentStrings().listUnread }
    }

    /// A named create in an environment (`cloud new-machine --name N --environment E`) refused so it makes no
    /// second machine named N: the machine list is not current, or N exists or is being made.
    public nonisolated struct NameRefused: LocalizedError, CustomStringConvertible, Equatable {
        public var name: String
        public var named: CloudMachineRequest.NamedCreate
        public var errorDescription: String? { description }
        public var description: String {
            named == .unread ? CloudEnvironmentStrings().nameUnread(name) : CloudEnvironmentStrings().nameTaken(name)
        }

        /// Throws the refusal `named` is for `name`; nothing for ``CloudMachineRequest/NamedCreate/free``.
        public static func check(_ name: String?, _ named: CloudMachineRequest.NamedCreate) throws {
            if let name, named != .free { throw Self(name: name, named: named) }
        }
    }

    /// `--environment`'s word, trimmed; ``Unknown`` for an empty one.
    public nonisolated static func word(_ text: String) throws -> String {
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { throw Unknown() }
        return word
    }

    /// The id `wanted` names: an `env_…` id as given, else the id of the environment in `options` (the app's
    /// `cloud.environment.list`) with that name, exactly or in any case; ``Unknown`` for a name none has.
    public nonisolated static func id(for wanted: String, in options: [Self]) throws -> String {
        if wanted.hasPrefix("env_") { return wanted }
        guard let match = options.first(where: { $0.name == wanted })
            ?? options.first(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }) else { throw Unknown() }
        return match.id
    }

    /// The id `wanted` names, reading the team's environments with `loading` only for a name: an `env_…` id
    /// needs no list. A list that fails to load is ``ListUnread``, never an empty one (``Unknown``).
    @MainActor
    public static func id(for wanted: String, loading: @MainActor () async throws -> [Self]) async throws -> String {
        if wanted.hasPrefix("env_") { return wanted }
        let options: [Self]
        do { options = try await loading() } catch is CancellationError { throw CancellationError() } catch { throw ListUnread() }
        return try id(for: wanted, in: options)
    }
}
