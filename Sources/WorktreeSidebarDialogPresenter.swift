import AppKit
import Foundation

/// Owns the localized AppKit prompts for create, delete, and failure flows.
@MainActor
struct WorktreeSidebarDialogPresenter: WorktreeSidebarDialogPresenting {
    func promptForBranchName(projectName: String) -> String? {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "worktreeSidebar.create.title",
            defaultValue: "Create a worktree"
        )
        let messageFormat = String(
            localized: "worktreeSidebar.create.message",
            defaultValue: "Enter a branch name for a new worktree in “%@”. Invalid character runs become hyphens."
        )
        alert.informativeText = String.localizedStringWithFormat(messageFormat, projectName)
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        textField.placeholderString = String(
            localized: "worktreeSidebar.create.placeholder",
            defaultValue: "feature-name"
        )
        alert.accessoryView = textField
        alert.addButton(withTitle: String(
            localized: "worktreeSidebar.create.action",
            defaultValue: "Create Worktree"
        ))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        alert.window.initialFirstResponder = textField
        guard runCmuxModalAlert(alert) == .alertFirstButtonReturn else { return nil }
        return textField.stringValue
    }

    func confirmDeletion(
        _ inspection: WorktreeSidebarDeletionInspection,
        force: Bool
    ) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = force
            ? String(
                localized: "worktreeSidebar.delete.force.title",
                defaultValue: "Force remove this worktree?"
            )
            : String(
                localized: "worktreeSidebar.delete.title",
                defaultValue: "Remove this worktree?"
            )

        var lines = [pathLine(inspection.worktree.path)]
        lines.append(uncommittedLine(inspection))
        lines.append(ignoredFilesLine(inspection))
        lines.append(unpushedLine(inspection))
        lines.append(branchLine(inspection.branchDisposition))
        if inspection.hasInitializedSubmodules {
            lines.append(String(
                localized: "worktreeSidebar.delete.submodules",
                defaultValue: "Initialized submodules: Yes. Git requires --force to remove this checkout."
            ))
        }
        if inspection.worktree.isPrunable {
            lines.append(String(
                localized: "worktreeSidebar.delete.prunable",
                defaultValue: "Git reports that the working directory is missing. cmux will prune its stale worktree registration."
            ))
        }
        if force {
            lines.append(forceWarning(inspection))
        }
        alert.informativeText = lines.joined(separator: "\n\n")
        let primaryTitle: String
        if force {
            primaryTitle = String(
                localized: "worktreeSidebar.delete.force.action",
                defaultValue: "Force Remove"
            )
        } else if inspection.requiresForceRemoval {
            primaryTitle = String(
                localized: "worktreeSidebar.delete.continue",
                defaultValue: "Continue"
            )
        } else if inspection.worktree.isPrunable {
            primaryTitle = String(
                localized: "worktreeSidebar.delete.pruneAction",
                defaultValue: "Prune Worktree"
            )
        } else {
            primaryTitle = String(
                localized: "worktreeSidebar.delete.action",
                defaultValue: "Remove Worktree"
            )
        }
        alert.addButton(withTitle: primaryTitle)
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        return runCmuxModalAlert(alert) == .alertFirstButtonReturn
    }

    func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "worktreeSidebar.error.title",
            defaultValue: "Couldn’t complete the worktree action"
        )
        alert.informativeText = errorMessage(error)
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        _ = runCmuxModalAlert(alert)
    }

    func presentPreservedBranch(name: String, reason: String) {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "worktreeSidebar.delete.branchPreserved.title",
            defaultValue: "Worktree removed; branch preserved"
        )
        let format = String(
            localized: "worktreeSidebar.delete.branchPreserved.message",
            defaultValue: "Git kept the branch “%@” because safe deletion was refused. cmux never escalates to branch -D.\n\n%@"
        )
        alert.informativeText = String.localizedStringWithFormat(
            format,
            name,
            boundedDetails(reason)
        )
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        _ = runCmuxModalAlert(alert)
    }

    private func pathLine(_ path: String) -> String {
        let format = String(
            localized: "worktreeSidebar.delete.path",
            defaultValue: "Path: %@"
        )
        return String.localizedStringWithFormat(format, path)
    }

    private func uncommittedLine(_ inspection: WorktreeSidebarDeletionInspection) -> String {
        if inspection.worktree.isPrunable {
            return String(
                localized: "worktreeSidebar.delete.uncommitted.missing",
                defaultValue: "Uncommitted changes present: No working directory remains to inspect."
            )
        }
        return inspection.hasUncommittedChanges
            ? String(
                localized: "worktreeSidebar.delete.uncommitted.yes",
                defaultValue: "Uncommitted changes present: Yes"
            )
            : String(
                localized: "worktreeSidebar.delete.uncommitted.no",
                defaultValue: "Uncommitted changes present: No"
            )
    }

    private func unpushedLine(_ inspection: WorktreeSidebarDeletionInspection) -> String {
        let count = inspection.unpushedCommitCount
        if inspection.worktree.branchName == nil {
            if count == 0 {
                return String(
                    localized: "worktreeSidebar.delete.unpushed.detached.no",
                    defaultValue: "Unpushed commits unique to this detached HEAD: No"
                )
            }
            let format = String(
                localized: "worktreeSidebar.delete.unpushed.detached.yes",
                defaultValue: "Unpushed commits unique to this detached HEAD: Yes (%lld not reachable from a local or remote-tracking branch)"
            )
            return String.localizedStringWithFormat(format, Int64(count))
        }
        if count == 0 {
            return String(
                localized: "worktreeSidebar.delete.unpushed.no",
                defaultValue: "Unpushed commits unique to this branch: No"
            )
        }
        let format = String(
            localized: "worktreeSidebar.delete.unpushed.yes",
            defaultValue: "Unpushed commits unique to this branch: Yes (%lld not reachable from another local or remote-tracking branch)"
        )
        return String.localizedStringWithFormat(format, Int64(count))
    }

    private func ignoredFilesLine(_ inspection: WorktreeSidebarDeletionInspection) -> String {
        if inspection.worktree.isPrunable {
            return String(
                localized: "worktreeSidebar.delete.ignored.missing",
                defaultValue: "Ignored files at risk: No working directory remains to inspect."
            )
        }
        return inspection.hasIgnoredFiles
            ? String(
                localized: "worktreeSidebar.delete.ignored.yes",
                defaultValue: "Ignored files at risk: Yes. Removing the worktree permanently deletes them."
            )
            : String(
                localized: "worktreeSidebar.delete.ignored.no",
                defaultValue: "Ignored files at risk: No"
            )
    }

    private func branchLine(
        _ disposition: WorktreeSidebarDeletionInspection.BranchDisposition
    ) -> String {
        switch disposition {
        case .deleteMerged(let name):
            let format = String(
                localized: "worktreeSidebar.delete.branch.delete",
                defaultValue: "Branch after removal: Delete “%@” with git branch -d (it is fully merged)."
            )
            return String.localizedStringWithFormat(format, name)
        case .keepUnmerged(let name):
            let format = String(
                localized: "worktreeSidebar.delete.branch.keep",
                defaultValue: "Branch after removal: Keep “%@” (Git reports it is not fully merged)."
            )
            return String.localizedStringWithFormat(format, name)
        case .noLocalBranch:
            return String(
                localized: "worktreeSidebar.delete.branch.none",
                defaultValue: "Branch after removal: No local branch will be deleted."
            )
        }
    }

    private func forceWarning(_ inspection: WorktreeSidebarDeletionInspection) -> String {
        if inspection.hasUncommittedChanges {
            return String(
                localized: "worktreeSidebar.delete.force.warning.dirty",
                defaultValue: "Force removal permanently deletes files not preserved by Git, including uncommitted, untracked, and ignored files in this working directory and its submodules."
            )
        }
        return String(
            localized: "worktreeSidebar.delete.force.warning.submodules",
            defaultValue: "The worktree is clean, but Git requires force because it contains initialized submodules. Force removal deletes the checkout, its submodule directories, and any ignored files inside them."
        )
    }

    private func errorMessage(_ error: Error) -> String {
        guard let gitError = error as? WorktreeSidebarGitError else {
            return String(
                localized: "worktreeSidebar.error.unknown",
                defaultValue: "An unexpected error occurred."
            )
        }
        switch gitError {
        case .invalidBranchName(let name):
            let format = String(
                localized: "worktreeSidebar.error.invalidBranch",
                defaultValue: "“%@” cannot be converted into a valid Git branch name."
            )
            return String.localizedStringWithFormat(format, name)
        case .mainWorktree:
            return String(
                localized: "worktreeSidebar.error.mainWorktree",
                defaultValue: "The main worktree cannot be removed."
            )
        case .locked(let reason):
            if let reason, !reason.isEmpty {
                let format = String(
                    localized: "worktreeSidebar.error.locked.reason",
                    defaultValue: "This worktree is locked: %@"
                )
                return String.localizedStringWithFormat(format, reason)
            }
            return String(
                localized: "worktreeSidebar.error.locked",
                defaultValue: "This worktree is locked and cannot be removed."
            )
        case .containsRegisteredWorktrees:
            return String(
                localized: "worktreeSidebar.error.containsWorktrees",
                defaultValue: "Git reports another registered worktree inside this worktree. Remove nested worktrees first."
            )
        case .worktreeNotFound:
            return String(
                localized: "worktreeSidebar.error.notFound",
                defaultValue: "Git no longer reports this worktree. Refresh the sidebar and try again."
            )
        case .worktreeChanged:
            return String(
                localized: "worktreeSidebar.error.changed",
                defaultValue: "The worktree changed after confirmation, so nothing was removed. Review the refreshed safety details and try again."
            )
        case .forceRequired:
            return String(
                localized: "worktreeSidebar.error.forceRequired",
                defaultValue: "Git requires an explicit force confirmation before removing this worktree."
            )
        case .submoduleInitializationFailed(_, let details):
            let base = String(
                localized: "worktreeSidebar.error.submodules",
                defaultValue: "The worktree was created, but its submodules could not be initialized."
            )
            return joined(base: base, details: details)
        case .commandFailed(_, let details):
            let base = String(
                localized: "worktreeSidebar.error.git",
                defaultValue: "Git could not complete the operation."
            )
            return joined(base: base, details: details)
        }
    }

    private func joined(base: String, details: String) -> String {
        let bounded = boundedDetails(details)
        return bounded.isEmpty ? base : base + "\n\n" + bounded
    }

    private func boundedDetails(_ details: String) -> String {
        String(details.prefix(2_000))
    }
}
