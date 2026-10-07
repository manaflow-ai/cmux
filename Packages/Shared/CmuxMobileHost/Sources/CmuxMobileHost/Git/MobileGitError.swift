/// The git family's refusals in the shared daemon error shape.
extension MobileDaemonError {
    static let gitNotARepoCode = "git.not_a_repo"

    static func gitForbidden(_ message: String = "outside the folders this Mac shares") -> MobileDaemonError {
        MobileDaemonError(code: "git.forbidden", message: message)
    }

    static func gitNotARepo(_ message: String = "not in a git repository") -> MobileDaemonError {
        MobileDaemonError(code: gitNotARepoCode, message: message)
    }

    static func gitFailed(_ message: String = "the session host could not read the repository") -> MobileDaemonError {
        MobileDaemonError(code: "git.failed", message: message, retryable: true)
    }
}
