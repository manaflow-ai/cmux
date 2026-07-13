#if os(iOS)
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport

enum TaskComposerSubmissionPhase: Equatable {
    case idle
    case preparing
    case committed

    var disablesRequestEditing: Bool {
        self != .idle
    }

    var showsProgress: Bool {
        self != .idle
    }

    var locksDismissal: Bool {
        self == .committed
    }
}

extension TaskComposerSheet {
    static var createAccessibilityHint: String {
        L10n.string(
            "mobile.taskComposer.create.accessibilityHint",
            defaultValue: "Creates the task on the selected Mac."
        )
    }

    static var machineAccessibilityHint: String {
        L10n.string(
            "mobile.taskComposer.machine.accessibilityHint",
            defaultValue: "Chooses the Mac that will run this task."
        )
    }

    static var templateAccessibilityHint: String {
        L10n.string(
            "mobile.taskComposer.template.accessibilityHint",
            defaultValue: "Selects this template for the task."
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
        case .unsupported:
            return L10n.string("mobile.taskComposer.failure.unsupported", defaultValue: "That Mac does not support this action.")
        }
    }

    /// The directory the composer pre-fills: the template default, then the
    /// last successful directory for the selected Mac, then home.
    static func suggestedDirectory(
        template: MobileTaskTemplate?,
        macDeviceID: String,
        templateStore: (any MobileTaskTemplateStoring)?
    ) -> String {
        if let defaultDirectory = template?.defaultDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !defaultDirectory.isEmpty {
            return defaultDirectory
        }
        if let lastDirectory = templateStore?.lastDirectory(macDeviceID: macDeviceID)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !lastDirectory.isEmpty {
            return lastDirectory
        }
        return "~"
    }
}
#endif
