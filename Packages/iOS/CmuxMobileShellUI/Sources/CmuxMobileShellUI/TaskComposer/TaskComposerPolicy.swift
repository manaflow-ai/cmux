#if os(iOS)
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport

enum TaskComposerSubmissionPhase: Equatable {
    case idle
    case preparing
    case committed
    case retryReady

    var allowsSubmission: Bool { self == .idle || self == .retryReady }
    var offersRetry: Bool { self == .retryReady }
    var disablesRequestEditing: Bool { self == .preparing || self == .committed }
    var showsProgress: Bool { self == .preparing || self == .committed }
    var locksDismissal: Bool { self == .committed }
}

enum MobileTaskComposerPolicy {
    static var draftPersistenceFailureMessage: String {
        L10n.string(
            "mobile.taskComposer.failure.draftPersistence",
            defaultValue: "cmux couldn’t save this draft safely. Reopen the composer and try again."
        )
    }

    static func failureMessage(_ failure: MobileWorkspaceMutationFailure) -> String {
        switch failure {
        case .notConnected:
            return L10n.string("mobile.taskComposer.failure.notConnected", defaultValue: "That Mac is not connected.")
        case .requestTimedOut:
            return L10n.string("mobile.taskComposer.failure.timedOut", defaultValue: "The Mac did not respond in time.")
        case .authorizationFailed:
            return L10n.string("mobile.taskComposer.failure.authorization", defaultValue: "That Mac did not authorize the request.")
        case .busy:
            return L10n.string("mobile.taskComposer.failure.busy", defaultValue: "Another workspace action is still finishing.")
        case .rejected:
            return L10n.string("mobile.taskComposer.failure.rejected", defaultValue: "The Mac rejected the task.")
        case .invalidWorkingDirectory:
            return L10n.string("mobile.taskComposer.failure.invalidWorkingDirectory", defaultValue: "Choose an existing folder on that Mac.")
        case .persistenceUnavailable:
            return L10n.string("mobile.taskComposer.failure.persistence", defaultValue: "The Mac could not safely reserve this task.")
        case .alreadyCompleted:
            return L10n.string(
                "mobile.taskComposer.failure.alreadyCompleted",
                defaultValue: "The Mac already accepted this task. Refresh workspaces before trying again."
            )
        case .unsupported:
            return L10n.string("mobile.taskComposer.failure.unsupported", defaultValue: "That Mac does not support this action.")
        }
    }

    @MainActor
    static func suggestedDirectory(
        template: MobileTaskTemplate?,
        macDeviceID: String,
        templateStore: (any MobileTaskTemplateStoring)?,
        openDirectory: String? = nil
    ) -> String {
        if let directory = template?.defaultDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !directory.isEmpty {
            return directory
        }
        if let directory = openDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !directory.isEmpty {
            return directory
        }
        if let directory = templateStore?.lastDirectory(macDeviceID: macDeviceID)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !directory.isEmpty {
            return directory
        }
        return "~"
    }

    static func preferredOpenDirectory(
        workspaces: [MobileWorkspacePreview],
        selectedWorkspaceID: MobileWorkspacePreview.ID?,
        macDeviceID: String,
        connectedMacDeviceID: String?
    ) -> String? {
        let includeUnscoped = macDeviceID == connectedMacDeviceID
        let matching = workspaces.filter {
            $0.macDeviceID == macDeviceID || ($0.macDeviceID == nil && includeUnscoped)
        }
        let ordered = matching.sorted { lhs, rhs in
            if (lhs.id == selectedWorkspaceID) != (rhs.id == selectedWorkspaceID) {
                return lhs.id == selectedWorkspaceID
            }
            return (lhs.lastActivityAt ?? .distantPast) > (rhs.lastActivityAt ?? .distantPast)
        }
        for workspace in ordered {
            if let focused = workspace.terminals.first(where: \.isFocused)?.currentDirectory,
               !focused.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return focused
            }
            if let current = workspace.currentDirectory,
               !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return current
            }
            if let terminal = workspace.terminals.compactMap(\.currentDirectory).first(where: {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) {
                return terminal
            }
        }
        return nil
    }
}
#endif
