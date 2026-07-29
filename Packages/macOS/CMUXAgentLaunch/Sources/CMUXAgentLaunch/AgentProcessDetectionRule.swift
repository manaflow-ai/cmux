/// The process-name and argument fields used to prefilter an agent detection rule.
public struct AgentProcessDetectionRule: Equatable, Sendable {
    let processName: String?
    let processNames: [String]
    let argvContains: [String]
    let alternateProcessNames: [String]
    let alternateArgvContains: [String]
    let alternateArgvContainsAny: [String]

    /// Creates the prefilter projection of an agent detection rule.
    ///
    /// - Parameters:
    ///   - processName: The rule's primary process name.
    ///   - processNames: Additional primary process names.
    ///   - argvContains: Argument needles used without a process-name constraint.
    ///   - alternateProcessNames: Process names that constrain alternate matches.
    ///   - alternateArgvContains: Argument needles for alternate matches.
    ///   - alternateArgvContainsAny: Any-of argument needles for alternate matches.
    public init(
        processName: String?,
        processNames: [String],
        argvContains: [String],
        alternateProcessNames: [String],
        alternateArgvContains: [String],
        alternateArgvContainsAny: [String]
    ) {
        self.processName = processName
        self.processNames = processNames
        self.argvContains = argvContains
        self.alternateProcessNames = alternateProcessNames
        self.alternateArgvContains = alternateArgvContains
        self.alternateArgvContainsAny = alternateArgvContainsAny
    }
}
