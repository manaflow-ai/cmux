import Foundation

struct SudoCLIMessages: Sendable {
    var usage: String {
        String(
            localized: "sudo.cli.usage",
            defaultValue: "Usage: cmux sudo run [-r reason] [-t timeout] (-c 'command' | script.sh | -)\n       cmux sudo pending"
        )
    }

    var defaultReason: String {
        String(localized: "sudo.cli.default_reason", defaultValue: "(no reason given)")
    }

    var timeoutPositiveInteger: String {
        String(
            localized: "sudo.cli.error.timeout_positive_integer",
            defaultValue: "sudo: timeout must be a positive integer"
        )
    }

    var timeoutTooLarge: String {
        String(
            localized: "sudo.cli.error.timeout_too_large",
            defaultValue: "sudo: timeout must not exceed 86400 seconds"
        )
    }

    var missingInput: String {
        String(
            localized: "sudo.cli.error.missing_input",
            defaultValue: "sudo: nothing to run; pass -c 'command', a script file, or -"
        )
    }

    var invalidUTF8: String {
        String(
            localized: "sudo.cli.error.invalid_utf8",
            defaultValue: "sudo: the script must be valid UTF-8"
        )
    }

    var scriptTooLarge: String {
        String(
            localized: "sudo.cli.error.script_too_large",
            defaultValue: "sudo: the script exceeds the 16 MiB limit"
        )
    }

    var appLaunchFailed: String {
        String(
            localized: "sudo.cli.error.app_launch_failed",
            defaultValue: "sudo: could not launch the enclosing cmux app"
        )
    }

    var requestWriteFailed: String {
        String(
            localized: "sudo.cli.error.request_write_failed",
            defaultValue: "sudo: could not write the approval request"
        )
    }

    var denied: String {
        String(localized: "sudo.cli.denied", defaultValue: "sudo: request denied")
    }

    var failed: String {
        String(localized: "sudo.cli.failed", defaultValue: "sudo: request failed")
    }

    var noPendingRequests: String {
        String(localized: "sudo.cli.pending.none", defaultValue: "(none)")
    }

    func unknownFlag(_ flag: String) -> String {
        format(
            key: "sudo.cli.error.unknown_flag",
            defaultValue: "sudo: unknown flag: %@",
            flag
        )
    }

    func unexpectedArgument(_ argument: String) -> String {
        format(
            key: "sudo.cli.error.unexpected_argument",
            defaultValue: "sudo: unexpected argument: %@",
            argument
        )
    }

    func scriptNotFound(_ path: String) -> String {
        format(
            key: "sudo.cli.error.script_not_found",
            defaultValue: "sudo: script not found: %@",
            path
        )
    }

    func queued(id: String, timeoutSeconds: Int) -> String {
        format(
            key: "sudo.cli.queued",
            defaultValue: "sudo: request %@ queued; waiting up to %d seconds for approval in cmux…",
            id,
            timeoutSeconds
        )
    }

    func pendingTimeout(id: String) -> String {
        format(
            key: "sudo.cli.timeout.pending",
            defaultValue: "sudo: timed out waiting for approval (request %@ was not approved)",
            id
        )
    }

    func approvedTimeout(id: String) -> String {
        format(
            key: "sudo.cli.timeout.approved",
            defaultValue: "sudo: request %@ was approved, but execution did not complete before the timeout",
            id
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
