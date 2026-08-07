import Foundation

struct SudoApprovalViewMessages: Sendable {
    var heading: String {
        String(
            localized: "sudo.approval.heading",
            defaultValue: "Administrator access requested"
        )
    }

    var warning: String {
        String(
            localized: "sudo.approval.warning",
            defaultValue: "Review the entire script before approving. It will run with administrator privileges."
        )
    }

    var requestIDLabel: String {
        String(localized: "sudo.approval.request_id", defaultValue: "Request ID")
    }

    var reasonLabel: String {
        String(localized: "sudo.approval.reason", defaultValue: "Reason")
    }

    var requesterLabel: String {
        String(localized: "sudo.approval.requester", defaultValue: "Requested by")
    }

    var workingDirectoryLabel: String {
        String(localized: "sudo.approval.working_directory", defaultValue: "Working directory")
    }

    var queuedLabel: String {
        String(localized: "sudo.approval.queued", defaultValue: "Queued")
    }

    var scriptLabel: String {
        String(localized: "sudo.approval.script", defaultValue: "Script to run as root")
    }

    var approveButton: String {
        String(
            localized: "sudo.approval.approve",
            defaultValue: "Approve with Touch ID"
        )
    }

    var denyButton: String {
        String(localized: "sudo.approval.deny", defaultValue: "Deny")
    }

    var waitingStatus: String {
        String(localized: "sudo.approval.status.waiting", defaultValue: "Waiting for approval")
    }

    var decidingStatus: String {
        String(localized: "sudo.approval.status.deciding", defaultValue: "Applying decision…")
    }

    var approvedStatus: String {
        String(
            localized: "sudo.approval.status.approved",
            defaultValue: "Approved — starting the secure runner…"
        )
    }

    var executingStatus: String {
        String(
            localized: "sudo.approval.status.executing",
            defaultValue: "Running with administrator privileges…"
        )
    }

    func windowTitle(requestID: String) -> String {
        format(
            key: "sudo.approval.window_title",
            defaultValue: "Administrator request %@",
            requestID
        )
    }

    func requester(command: String, processIdentifier: Int32) -> String {
        format(
            key: "sudo.approval.requester_value",
            defaultValue: "%1$@ (PID %2$d)",
            command,
            processIdentifier
        )
    }

    private func format(
        key: StaticString,
        defaultValue: String.LocalizationValue,
        _ arguments: any CVarArg...
    ) -> String {
        let localized = String(localized: key, defaultValue: defaultValue)
        return String(format: localized, locale: Locale.current, arguments: arguments)
    }
}
