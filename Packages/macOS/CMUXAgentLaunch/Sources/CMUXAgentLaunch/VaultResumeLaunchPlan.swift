import Foundation

/// The shell dialect at the boundary where Vault startup input is typed.
public enum VaultResumeShellDialect: Equatable, Sendable {
    /// A POSIX-compatible login shell, including zsh, bash, fish, and csh.
    case posix
    /// Nushell, which delegates generated POSIX text through `/bin/sh`.
    case nushell
}

/// The immutable result of planning one Vault resume request.
public struct VaultResumeLaunchPlan: Equatable, Sendable {
    /// The route selected for the launch.
    public enum Strategy: Equatable, Sendable {
        /// Use `cmux restore <kind> <checkpoint>` and a structured record.
        case restoreVerb
        /// Use the bounded rendered command compatibility path.
        case legacyCommand
    }

    /// Why the rendered compatibility path was selected.
    public enum LegacyFallbackReason: String, Equatable, Sendable {
        /// No safe structured snapshot could be made from the entry.
        case missingStructuredSnapshot
        /// The registration identity or environment prefix is not representable.
        case unrepresentableRegistration
        /// Structured metadata exists, but its resume argv cannot be prepared.
        case unavailableStructuredArguments
    }

    /// Structured data copied into the app's restore-record snapshot.
    public struct StructuredSnapshot: Equatable, Sendable {
        /// Restore selector kind.
        public let kind: String
        /// Restore selector checkpoint identifier.
        public let sessionID: String
        /// Cwd persisted on the restore record.
        public let workingDirectory: String?
        /// Captured launch argv before the provider resume arguments are applied.
        public let launchArguments: [String]
        /// Replay-safe environment values captured by the entry.
        public let environment: [String: String]
        /// Normalized registration, when this is a registry-owned entry.
        public let registration: VaultResumeLaunchRequest.Registration?
        /// Hook-observed permission mode, when supplied by the provider.
        public let permissionMode: String?
        /// Sanitized provider resume argv proven to be constructible by the planner.
        public let preparedResumeArguments: [String]

        /// Creates a structured restore snapshot projection.
        init(
            kind: String,
            sessionID: String,
            workingDirectory: String?,
            launchArguments: [String],
            environment: [String: String],
            registration: VaultResumeLaunchRequest.Registration?,
            permissionMode: String?,
            preparedResumeArguments: [String]
        ) {
            self.kind = kind
            self.sessionID = sessionID
            self.workingDirectory = workingDirectory
            self.launchArguments = launchArguments
            self.environment = environment
            self.registration = registration
            self.permissionMode = permissionMode
            self.preparedResumeArguments = preparedResumeArguments
        }
    }

    /// Maximum UTF-8 bytes admitted for the rendered compatibility command.
    public static let maximumLegacyResumeInputBytes = 900

    /// The route selected by the planner.
    public let strategy: Strategy
    /// The POSIX command body before shell-dialect wrapping.
    public let posixCommand: String
    /// Cwd to request when creating the terminal surface.
    public let workingDirectory: String?
    /// Structured restore data, present only for ``Strategy/restoreVerb``.
    public let structuredSnapshot: StructuredSnapshot?
    /// The explicit compatibility reason, present only for ``Strategy/legacyCommand``.
    public let legacyFallbackReason: LegacyFallbackReason?

    /// Creates a launch plan.
    ///
    /// Callers should normally use ``VaultResumeLaunchPlanner`` so the strategy
    /// and its invariants are validated together.
    init(
        strategy: Strategy,
        posixCommand: String,
        workingDirectory: String?,
        structuredSnapshot: StructuredSnapshot?,
        legacyFallbackReason: LegacyFallbackReason?
    ) {
        self.strategy = strategy
        self.posixCommand = posixCommand
        self.workingDirectory = workingDirectory
        self.structuredSnapshot = structuredSnapshot
        self.legacyFallbackReason = legacyFallbackReason
    }

    /// Renders startup input for the shell that will parse it.
    ///
    /// Restore-verb plans retain their historical leading space, which keeps
    /// the selector out of shell history on shells that support that
    /// convention. Compatibility commands are rendered exactly as recorded.
    ///
    /// - Parameter dialect: Shell syntax accepted by the destination surface.
    /// - Returns: One complete startup line, including its trailing newline.
    public func startupInput(for dialect: VaultResumeShellDialect) -> String {
        let rendered: String
        switch dialect {
        case .posix:
            rendered = posixCommand
        case .nushell:
            rendered = NushellTypedShellCommand().wrapping(posixCommand: posixCommand)
        }
        return "\(rendered)\n"
    }
}
