import Foundation

extension DeclarativeTerminalConfiguration {
    /// Immutable values read from the declarative terminal configuration.
    public struct Snapshot: Equatable, Sendable {
        /// `nil` means the new policy key is absent or invalid.
        public var workingDirectoryPolicy: NewSurfaceWorkingDirectoryPolicy?

        /// Configured fixed path, or an empty string when absent.
        public var workingDirectoryPath: String

        /// Whether the configured fixed path is currently usable.
        /// A false value fails closed until a fresh validation result arrives.
        public var fixedPathIsUsable: Bool

        /// Configured shell invocation mode, defaulting to login.
        public var shellStartupMode: ShellStartupMode

        /// Trimmed startup command, or an empty string when absent.
        public var shellStartupCommand: String

        /// Legacy working-directory inheritance used only when the new policy
        /// key is absent or invalid.
        public var legacyInheritanceEnabled: Bool

        /// Creates a snapshot of declarative terminal values.
        ///
        /// - Parameters:
        ///   - workingDirectoryPolicy: Parsed policy, or `nil` when the file
        ///     omitted or invalidated it.
        ///   - workingDirectoryPath: Raw fixed path value.
        ///   - fixedPathIsUsable: Filesystem validation result.
        ///   - shellStartupMode: Parsed shell startup mode.
        ///   - shellStartupCommand: Raw startup command value.
        ///   - legacyInheritanceEnabled: Compatibility fallback for an absent
        ///     policy key.
        public init(
            workingDirectoryPolicy: NewSurfaceWorkingDirectoryPolicy? = nil,
            workingDirectoryPath: String = "",
            fixedPathIsUsable: Bool = false,
            shellStartupMode: ShellStartupMode = .login,
            shellStartupCommand: String = "",
            legacyInheritanceEnabled: Bool = true
        ) {
            self.workingDirectoryPolicy = workingDirectoryPolicy
            self.workingDirectoryPath = workingDirectoryPath
            self.fixedPathIsUsable = fixedPathIsUsable
            self.shellStartupMode = shellStartupMode
            self.shellStartupCommand = shellStartupCommand
            self.legacyInheritanceEnabled = legacyInheritanceEnabled
        }

        /// Resolves the authored policy, applying the legacy compatibility
        /// value only when the declarative key is absent or invalid.
        ///
        /// - Parameter legacyInheritanceEnabled: Optional override used by
        ///   callers that need to evaluate a snapshot against a hypothetical
        ///   legacy value. When omitted, the value captured in this snapshot is
        ///   used.
        /// - Returns: The effective working-directory policy.
        public func effectiveWorkingDirectoryPolicy(
            legacyInheritanceEnabled override: Bool? = nil
        ) -> NewSurfaceWorkingDirectoryPolicy {
            workingDirectoryPolicy
                ?? ((override ?? legacyInheritanceEnabled)
                    ? .inheritActivePane
                    : .workspaceRoot)
        }

        /// Expands and normalizes the configured path without filesystem I/O.
        public var expandedWorkingDirectoryPath: String? {
            let trimmed = workingDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let expanded = (trimmed as NSString).expandingTildeInPath
            guard !expanded.isEmpty, (expanded as NSString).isAbsolutePath else { return nil }
            return URL(fileURLWithPath: expanded).standardizedFileURL.path
        }
    }
}
