import Foundation

/// Resolves one caller TTY through injected runtime and shell-report snapshots.
/// Current Ghostty PTYs are authoritative. A unique shell-reported fallback
/// covers nested terminal multiplexers, whose pane TTY differs from Ghostty's
/// outer PTY; ambiguity at either tier fails closed.
nonisolated struct TerminalCallerTTYResolver: Sendable {
    private let liveCandidates: [(binding: TerminalCallerTTYBinding, ttyName: String)]
    private let reportedCandidates: [(binding: TerminalCallerTTYBinding, ttyName: String)]

    init(
        liveCandidates: [(binding: TerminalCallerTTYBinding, ttyName: String)] = [],
        reportedCandidates: [(binding: TerminalCallerTTYBinding, ttyName: String)] = []
    ) {
        self.liveCandidates = liveCandidates
        self.reportedCandidates = reportedCandidates
    }

    func binding(for callerTTY: String) -> TerminalCallerTTYBinding? {
        guard let callerTTY = Self.normalizedName(callerTTY) else { return nil }
        let liveBindings = matchingBindings(for: callerTTY, in: liveCandidates)
        if let liveBinding = liveBindings.first {
            return liveBindings.count == 1 ? liveBinding : nil
        }

        let reportedBindings = matchingBindings(for: callerTTY, in: reportedCandidates)
        return reportedBindings.count == 1 ? reportedBindings.first : nil
    }

    static func normalizedName(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed != "not a tty" else {
            return nil
        }
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }

    private func matchingBindings(
        for callerTTY: String,
        in candidates: [(binding: TerminalCallerTTYBinding, ttyName: String)]
    ) -> Set<TerminalCallerTTYBinding> {
        Set(candidates.compactMap { candidate in
            Self.normalizedName(candidate.ttyName) == callerTTY ? candidate.binding : nil
        })
    }
}
