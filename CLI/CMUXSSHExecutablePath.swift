import Foundation

/// Resolves the local SSH executable for both the app and standalone CLI
/// targets. Debug integration tests may substitute a hermetic shim; release
/// builds always use the system OpenSSH binary.
struct CMUXSSHExecutablePathResolver: Sendable {
    private let environment: [String: String]

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    var path: String {
        #if DEBUG
        if let override = environment["CMUX_REMOTE_TMUX_SSH_FOR_TESTING"],
           !override.isEmpty {
            return override
        }
        #endif
        return "/usr/bin/ssh"
    }
}
