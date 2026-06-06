public import Foundation

/// Decides whether installing an update can proceed immediately or needs an explicit warning.
///
/// The gate is a stateless value so callers can inject it where update-install decisions are
/// made while tests exercise the same policy without launching the app.
public struct UpdateInstallGate: Sendable {
    /// Creates a terminal-session install gate.
    public init() {}

    /// A value snapshot of terminal sessions that would be affected by an update relaunch.
    public struct TerminalSessionSummary: Equatable, Sendable {
        /// The number of app windows represented in the summary.
        public var windowCount: Int
        /// The number of workspaces represented in the summary.
        public var workspaceCount: Int
        /// The number of terminal panels represented in the summary.
        public var terminalCount: Int
        /// The number of terminal panels that appear to have running commands.
        public var runningCommandCount: Int
        /// Stable terminal panel IDs represented in the summary, when available.
        public var terminalPanelIds: Set<UUID>
        /// Stable terminal panel IDs with running commands, when available.
        public var runningCommandPanelIds: Set<UUID>

        /// Creates a terminal-session summary.
        ///
        /// - Parameters:
        ///   - windowCount: The number of app windows represented in the summary.
        ///   - workspaceCount: The number of workspaces represented in the summary.
        ///   - terminalCount: The number of terminal panels represented in the summary.
        ///   - runningCommandCount: The number of terminal panels with running commands.
        ///   - terminalPanelIds: Stable terminal panel IDs represented in the summary.
        ///   - runningCommandPanelIds: Stable terminal panel IDs with running commands.
        public init(
            windowCount: Int,
            workspaceCount: Int,
            terminalCount: Int,
            runningCommandCount: Int,
            terminalPanelIds: Set<UUID> = [],
            runningCommandPanelIds: Set<UUID> = []
        ) {
            self.windowCount = windowCount
            self.workspaceCount = workspaceCount
            self.terminalCount = terminalCount
            self.runningCommandCount = runningCommandCount
            self.terminalPanelIds = terminalPanelIds
            self.runningCommandPanelIds = runningCommandPanelIds
        }

        /// An empty summary with no terminal sessions.
        public static let empty = TerminalSessionSummary(
            windowCount: 0,
            workspaceCount: 0,
            terminalCount: 0,
            runningCommandCount: 0
        )

        /// Whether the summary contains at least one terminal session.
        public var hasTerminalSessions: Bool {
            terminalCount > 0
        }

        /// Adds another summary into this summary.
        ///
        /// - Parameter other: The summary to add.
        public mutating func merge(_ other: TerminalSessionSummary) {
            windowCount += other.windowCount
            workspaceCount += other.workspaceCount
            terminalCount += other.terminalCount
            runningCommandCount += other.runningCommandCount
            terminalPanelIds.formUnion(other.terminalPanelIds)
            runningCommandPanelIds.formUnion(other.runningCommandPanelIds)
        }

        /// Returns whether a previous confirmation still covers this current summary.
        ///
        /// - Parameter confirmed: The previously confirmed terminal-session summary.
        /// - Returns: `true` when the current sessions are a subset of the confirmed sessions.
        public func isCovered(by confirmed: TerminalSessionSummary) -> Bool {
            guard hasTerminalSessions else { return true }
            guard confirmed.hasTerminalSessions else { return false }
            guard terminalIdentityIsCovered(by: confirmed) else { return false }
            guard runningCommandIdentityIsCovered(by: confirmed) else { return false }
            return terminalCount <= confirmed.terminalCount
                && runningCommandCount <= confirmed.runningCommandCount
                && workspaceCount <= confirmed.workspaceCount
                && windowCount <= confirmed.windowCount
        }

        private func terminalIdentityIsCovered(by confirmed: TerminalSessionSummary) -> Bool {
            if terminalPanelIds.isEmpty, confirmed.terminalPanelIds.isEmpty {
                return true
            }
            return terminalPanelIds.isSubset(of: confirmed.terminalPanelIds)
        }

        private func runningCommandIdentityIsCovered(by confirmed: TerminalSessionSummary) -> Bool {
            if runningCommandPanelIds.isEmpty, confirmed.runningCommandPanelIds.isEmpty {
                return true
            }
            return runningCommandPanelIds.isSubset(of: confirmed.runningCommandPanelIds)
        }
    }

    /// The install-gate decision for the current terminal-session summary.
    public enum Decision: Equatable, Sendable {
        /// Installation can proceed without showing a terminal-session warning.
        case installNow
        /// Installation needs explicit confirmation for the given terminal-session summary.
        case requireConfirmation(TerminalSessionSummary)
    }

    /// Decides whether installation can proceed using a simple boolean confirmation.
    ///
    /// - Parameters:
    ///   - summary: The current terminal-session summary.
    ///   - userAlreadyConfirmed: Whether the user has already accepted the warning.
    /// - Returns: The install decision for the current summary.
    public func decision(
        terminalSessions summary: TerminalSessionSummary,
        userAlreadyConfirmed: Bool
    ) -> Decision {
        guard !userAlreadyConfirmed, summary.hasTerminalSessions else {
            return .installNow
        }
        return .requireConfirmation(summary)
    }

    /// Decides whether installation can proceed using the previously confirmed summary.
    ///
    /// - Parameters:
    ///   - summary: The current terminal-session summary.
    ///   - confirmed: The terminal-session summary the user previously confirmed, if any.
    /// - Returns: The install decision for the current summary.
    public func decision(
        terminalSessions summary: TerminalSessionSummary,
        confirmedTerminalSessions confirmed: TerminalSessionSummary?
    ) -> Decision {
        guard summary.hasTerminalSessions else {
            return .installNow
        }
        if let confirmed, summary.isCovered(by: confirmed) {
            return .installNow
        }
        return .requireConfirmation(summary)
    }
}
