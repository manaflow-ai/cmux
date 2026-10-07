/// The files family's refusals in the shared daemon error shape, so a read
/// handler can throw them and channel handlers can refuse with them.
extension MobileDaemonError {
    static func filesForbidden(_ message: String = "outside the directories this Mac shares") -> MobileDaemonError {
        MobileDaemonError(code: "files.forbidden", message: message)
    }

    static func filesNotFound(_ message: String = "no such file") -> MobileDaemonError {
        MobileDaemonError(code: "files.not_found", message: message)
    }

    static func filesTooLarge(_ reason: String) -> MobileDaemonError {
        MobileDaemonError(code: "files.too_large", message: reason)
    }

    static func filesInvalid(_ message: String) -> MobileDaemonError {
        MobileDaemonError(code: "validation.invalid", message: message)
    }
}
