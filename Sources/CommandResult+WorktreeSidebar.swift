import CmuxFoundation
import Foundation

extension CommandResult {
    var worktreeSidebarSucceeded: Bool {
        executionError == nil && !timedOut && exitStatus == 0
    }

    var worktreeSidebarDetails: String {
        [stderr, stdout, executionError]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""
    }
}
