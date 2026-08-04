internal import Foundation

/// App-bundle-resolved command and validation strings for agent sidebar
/// control commands.
///
/// The app supplies these values so `String(localized:)` resolves against the
/// app bundle. The control-socket package formats the already-localized values
/// without binding localization lookup to its own resource-less bundle.
public struct ControlSidebarAgentStrings: Sendable, Equatable {
    let usageErrorFormat: String
    let setAgentPIDUsage: String
    let setAgentLifecycleUsage: String
    let processGenerationPIDMismatch: String
    let invalidLifecycleFormat: String
    let unsupportedLifecycleKeyFormat: String
    let processGenerationRequiredFormat: String
    let invalidProcessGenerationFormat: String

    /// Creates the localized agent-sidebar command strings.
    ///
    /// - Parameters:
    ///   - usageErrorFormat: The one-argument invalid-usage format.
    ///   - setAgentPIDUsage: The `set_agent_pid` command usage.
    ///   - setAgentLifecycleUsage: The `set_agent_lifecycle` command usage.
    ///   - processGenerationPIDMismatch: The mismatched-generation PID error.
    ///   - invalidLifecycleFormat: The lifecycle-token and usage error format.
    ///   - unsupportedLifecycleKeyFormat: The unsupported-key error format.
    ///   - processGenerationRequiredFormat: The missing-generation error format.
    ///   - invalidProcessGenerationFormat: The invalid-generation and usage
    ///     error format.
    public init(
        usageErrorFormat: String,
        setAgentPIDUsage: String,
        setAgentLifecycleUsage: String,
        processGenerationPIDMismatch: String,
        invalidLifecycleFormat: String,
        unsupportedLifecycleKeyFormat: String,
        processGenerationRequiredFormat: String,
        invalidProcessGenerationFormat: String
    ) {
        self.usageErrorFormat = usageErrorFormat
        self.setAgentPIDUsage = setAgentPIDUsage
        self.setAgentLifecycleUsage = setAgentLifecycleUsage
        self.processGenerationPIDMismatch = processGenerationPIDMismatch
        self.invalidLifecycleFormat = invalidLifecycleFormat
        self.unsupportedLifecycleKeyFormat = unsupportedLifecycleKeyFormat
        self.processGenerationRequiredFormat = processGenerationRequiredFormat
        self.invalidProcessGenerationFormat = invalidProcessGenerationFormat
    }

    static let englishFallback = Self(
        usageErrorFormat: "ERROR: Usage: %@",
        setAgentPIDUsage:
            "set_agent_pid <key> <pid> [--tab=<id>] [--panel=<id>] "
            + "[--pid=<pid> --pid-start-seconds=<seconds> "
            + "--pid-start-microseconds=<microseconds>]",
        setAgentLifecycleUsage:
            "set_agent_lifecycle <key> "
            + "<unknown|running|idle|needsInput> [--tab=<id>] "
            + "[--panel=<id>] [--pid=<pid> "
            + "--pid-start-seconds=<seconds> "
            + "--pid-start-microseconds=<microseconds>]",
        processGenerationPIDMismatch:
            "ERROR: Agent process generation PID does not match <pid>",
        invalidLifecycleFormat:
            "ERROR: Invalid agent lifecycle '%1$@' — usage: %2$@",
        unsupportedLifecycleKeyFormat:
            "ERROR: Unsupported agent lifecycle key '%@'",
        processGenerationRequiredFormat:
            "ERROR: Agent process generation is required for '%@'",
        invalidProcessGenerationFormat:
            "ERROR: Invalid agent process generation — usage: %@"
    )

    func usageError(usage: String) -> String {
        String(format: usageErrorFormat, usage)
    }

    func invalidLifecycle(_ lifecycle: String, usage: String) -> String {
        String(format: invalidLifecycleFormat, lifecycle, usage)
    }

    func unsupportedLifecycleKey(_ key: String) -> String {
        String(format: unsupportedLifecycleKeyFormat, key)
    }

    func processGenerationRequired(key: String) -> String {
        String(format: processGenerationRequiredFormat, key)
    }

    func invalidProcessGeneration(usage: String) -> String {
        String(format: invalidProcessGenerationFormat, usage)
    }
}
