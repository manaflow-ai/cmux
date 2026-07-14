import Foundation

/// The minimal immutable process identity needed for agent ancestry checks.
struct AgentProcessIdentity: Sendable, Equatable {
    var pid: Int
    var parentPID: Int
    var startedAt: TimeInterval
    var executableName: String?
    var arguments: [String]
}

extension AgentProcessIdentity {
    /// The cmux app is the ownership boundary for a terminal's process tree.
    ///
    /// A root agent's ancestors are its login shell and the cmux app. The app
    /// itself may have been launched by another coding agent, Xcode, or a test
    /// harness. Walking above it would misclassify that unrelated launcher as
    /// the terminal session's parent agent. Real subagents remain below this
    /// boundary, so their nearest agent ancestor is still discovered first.
    var isCmuxTerminalHost: Bool {
        ([executableName] + Array(arguments.prefix(1))).compactMap { $0 }.contains { candidate in
            let normalized = candidate
                .replacingOccurrences(of: "\\", with: "/")
                .lowercased()
            guard normalized.contains(".app/contents/macos/") else { return false }
            let basename = URL(fileURLWithPath: normalized).lastPathComponent
            return basename == "cmux" || basename.hasPrefix("cmux ")
        }
    }
}
